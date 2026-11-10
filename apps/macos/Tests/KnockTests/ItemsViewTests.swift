import Testing
import Foundation
@testable import Knock

private final class SubmittedReply: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PendingReply?
    var value: PendingReply? { lock.withLock { stored } }
    func set(_ reply: PendingReply) { lock.withLock { stored = reply } }
}

private struct SubmitParams: Decodable { let params: PendingReply }

/// WAG-315: one Ask view for one item or many. One item shows the single decision (no step bar); several
/// items show the step bar, one step per group (else per item), and send `item_answers`. A payload with no
/// items renders as in 0.2.20.
@MainActor
struct ItemsViewTests {
    // MARK: Fixtures

    private static func golden(_ name: String) throws -> [String: Any] {
        let asks = try #require(try ItemsDecodeTests.golden()["asks"] as? [[String: Any]])
        return try #require(asks.first { $0["name"] as? String == name })
    }

    private static func items(_ name: String) throws -> [Item] {
        let expect = try #require(try golden(name)["expect"] as? [String: Any])
        return try JSONDecoder().decode([Item].self, from: ItemsDecodeTests.data(try #require(expect["items"])))
    }

    private static func request(
        items: [Item] = [], questions: [Question] = [], status: CaseStatus = .needsYou, title: String = "Pricing", answers: [PointAnswer] = []
    ) -> Case {
        Case(
            id: "c1", taskId: "t", kind: .question, title: title, need: "Three decisions.", why: "Last screen.",
            recommendation: "", recommendationWhy: "", options: [], status: status, hasArtifact: false,
            createdAt: "2026-10-08T10:00:00Z", updatedAt: "2026-10-08T10:00:00Z",
            questions: questions, latestReplyAnswers: answers, items: items)
    }

    /// Three items of three kinds (the golden "multi-item" ask): pick one, pick several, write a reply.
    private func mixed(status: CaseStatus = .needsYou, itemAnswers: [ItemAnswer] = []) throws -> QuestionsDocModel {
        QuestionsDocModel(request: Self.request(items: try Self.items("multi-item-degrades-for-old-app"), status: status), itemAnswers: itemAnswers)
    }

    // MARK: One item or many

    @Test func oneItemShowsNoStepBarAndNoQuestionsDoc() throws {
        let single = Self.request(items: try Self.items("question-options"))
        #expect(!single.hasQuestionsDoc && !single.docUsesItems)
        #expect(AskBarMode.forCase(single) == .reply)
        #expect(!AskPanelLayout.showsQuestions(single))
        let reply = Self.request(items: try Self.items("reply-only"))
        #expect(!reply.hasQuestionsDoc)
    }

    @Test func severalItemsShowTheStepBar() throws {
        let many = Self.request(items: try Self.items("multi-item-degrades-for-old-app"))
        #expect(many.hasQuestionsDoc && many.docUsesItems)
        #expect(AskBarMode.forCase(many) == .answers)
        // The pane and the workspace column both ask the same rule, so both render the same body.
        #expect(AskPanelLayout.showsQuestions(many))
        let doc = QuestionsDocModel(request: many)
        #expect(doc.isStepped && doc.usesItems)
        #expect(doc.stepPills.map(\.isSend) == [false, false, false, true])
        #expect(doc.stepCrumb == "Decision 1 of 3" && doc.nextLabel == "Next")
    }

    @Test func eachItemOfAGroupIsItsOwnStep() throws {
        let doc = QuestionsDocModel(request: Self.request(items: try Self.items("questions-to-groups")))
        // WAG-364: three items in two groups: three steps and the Send pill. The group does not merge items.
        #expect(doc.questions.count == 3 && doc.stepPills.count == 4)
        #expect(doc.questions.map(\.id) == ["q1/p1", "q1/p2", "q2/p1"])
        #expect(doc.questions.map { $0.points.count } == [1, 1, 1])
        #expect(doc.totalPoints == 3)
    }

    @Test func aLoneItemWithNoGroupTakesItsQuestionAsTheStepTitle() throws {
        let items = [
            Item(id: "a", question: "Which layout?", options: [Option(id: "x", label: "Cards"), Option(id: "y", label: "Table")]),
            Item(id: "b", question: "Which badge?", options: [Option(id: "x", label: "Yes"), Option(id: "y", label: "No")]),
        ]
        let doc = QuestionsDocModel(request: Self.request(items: items))
        #expect(doc.questions.map(\.title) == ["Which layout?", "Which badge?"])
        #expect(doc.questions[0].points[0].hidesText)
    }

    // MARK: Old payloads

    @Test func aPayloadWithNoItemsKeepsItsQuestionsExactly() throws {
        let legacy: [Question] = [
            Question(id: "plans", title: "How many plans?", now: nil, points: [QuestionPoint(id: "count", text: "How many?", options: ["Two", "Three"])], artifactRef: nil, variants: nil, variantLabel: nil),
            Question(id: "cta", title: "Button?", now: nil, points: [QuestionPoint(id: "label", text: "Which?", options: nil)], artifactRef: nil, variants: nil, variantLabel: nil),
        ]
        let request = Self.request(questions: legacy)
        #expect(request.hasQuestionsDoc && !request.docUsesItems && request.docQuestions == legacy)
        var doc = QuestionsDocModel(request: request)
        #expect(!doc.usesItems && doc.isStepped)
        doc.choose("Two", question: "plans", point: "count")
        #expect(doc.answers() == [PointAnswer(questionId: "plans", pointId: "count", choice: "Two", note: nil)])
        #expect(doc.itemAnswers().isEmpty)
        // A partial set of answers still sends, as in 0.2.20.
        #expect(doc.sendsAnswers && doc.canSend)
        #expect(doc.reviewHint == nil && doc.reviewRows.map(\.pendingWord) == ["Skip", "Skip"])
    }

    @Test func theGoldenQuestionsRenderTheSameFromTheOldShapeAndFromItems() throws {
        let ask = try Self.golden("questions-to-groups")
        let input = try #require(ask["input"] as? [String: Any])
        let legacy = try JSONDecoder().decode([Question].self, from: ItemsDecodeTests.data(try #require(input["questions"])))
        let old = QuestionsDocModel(request: Self.request(questions: legacy))
        let new = QuestionsDocModel(request: Self.request(items: try Self.items("questions-to-groups")))
        // WAG-364: the old shape keeps one page per question; items are one step each. The points and their
        // answers are the same, in the same order.
        #expect(old.questions.flatMap { $0.points.map(\.text) } == new.questions.flatMap { $0.points.map(\.text) })
        #expect(old.questions.flatMap { $0.points.map(\.choiceLabels) } == new.questions.flatMap { $0.points.map(\.choiceLabels) })
        #expect(old.questions.map(\.title) == new.questions.compactMap(\.groupTitle).reduce(into: [String]()) { if $1 != $0.last { $0.append($1) } })
    }

    // MARK: Answers

    @Test func eachKindOfItemIsAnsweredItsOwnWay() throws {
        var doc = try mixed()
        let q = doc.questions
        // Pick one.
        doc.choose(q[0].points[0].choiceLabels[1], question: q[0].id, point: q[0].points[0].id)
        // Pick several: ticking twice unticks.
        let many = q[1].points[0]
        doc.choose(many.choiceLabels[0], question: q[1].id, point: many.id)
        doc.choose(many.choiceLabels[1], question: q[1].id, point: many.id)
        doc.choose(many.choiceLabels[1], question: q[1].id, point: many.id)
        doc.choose(many.choiceLabels[2], question: q[1].id, point: many.id)
        // Reply.
        doc.setText("  Ship in two steps  ", question: q[2].id, point: q[2].points[0].id)
        #expect(doc.answeredCount == 3 && doc.sendsAnswers)
        let answers = doc.itemAnswers()
        #expect(answers.map(\.itemId) == ["a", "b", "c"])
        #expect(answers[0].choice == "a2")
        #expect(answers[1].choices == ["b1", "b3"])
        #expect(answers[2].text == "Ship in two steps")
        #expect(doc.answers().isEmpty)
    }

    @Test func aPickSeveralItemStopsAtItsMax() throws {
        let item = Item(id: "m", question: "Areas?", select: .many, max: 2, options: [
            Option(id: "a", label: "A"), Option(id: "b", label: "B"), Option(id: "c", label: "C"),
        ])
        let other = Item(id: "o", question: "Other?", options: [Option(id: "x", label: "X"), Option(id: "y", label: "Y")])
        var doc = QuestionsDocModel(request: Self.request(items: [item, other]))
        let step = doc.questions[0]
        for label in ["A", "B", "C"] { doc.choose(label, question: step.id, point: "m") }
        // At the limit an unticked row does nothing, as in a single request (WAG-334).
        #expect(doc.draft(step.id, "m").choices == ["A", "B"])
        #expect(step.points[0].pickHint == "Pick up to 2")
    }

    @Test func aRequestWithItemsNeedsEveryItemAnsweredToDecide() throws {
        var doc = try mixed()
        let q = doc.questions
        doc.choose(q[0].points[0].choiceLabels[0], question: q[0].id, point: q[0].points[0].id)
        #expect(!doc.sendsAnswers && !doc.canSend)
        #expect(doc.sendLabel == "Send answers")
        // A note alone keeps talking: it sends as feedback, and the picks do not go with it.
        doc.note = "What about mobile?"
        #expect(doc.canSend && doc.isFeedbackOnly && doc.sendLabel == "Send feedback")
        doc.note = ""
        doc.choose(q[1].points[0].choiceLabels[0], question: q[1].id, point: q[1].points[0].id)
        doc.setText("Yes", question: q[2].id, point: q[2].points[0].id)
        #expect(doc.sendsAnswers && doc.sendLabel == "Send 3 answers")
        doc.jump(to: doc.reviewStep)
        #expect(doc.reviewHint == nil)
    }

    @Test func theReviewStepSaysWhyItCannotSendYet() throws {
        var doc = try mixed()
        doc.jump(to: doc.reviewStep)
        #expect(doc.reviewHint != nil)
        #expect(doc.reviewRows.map(\.pendingWord) == ["Open", "Open", "Open"])
        #expect(doc.reviewRows.allSatisfy { !$0.isDecided })
    }

    /// WAG-324: a step has one note field, the prompt bar's. Its text is the message, not an item note.
    @Test func theBarNoteIsTheOnlyNoteOfAStep() throws {
        var doc = try mixed()
        let point = doc.questions[0].points[0]
        doc.choose(point.choiceLabels[0], question: doc.questions[0].id, point: point.id)
        doc.note = "  Keep it small "
        #expect(doc.message == "Keep it small")
        #expect(doc.itemAnswers() == [ItemAnswer(itemId: "a", choice: "a1")])
    }

    @Test func aSentRequestShowsTheAnswersByLabel() throws {
        let sent = [ItemAnswer(itemId: "a", choice: "a2"), ItemAnswer(itemId: "b", choices: ["b1", "b3"]), ItemAnswer(itemId: "c", text: "Ship in two steps")]
        let doc = try mixed(status: .waitingOnAgent, itemAnswers: sent)
        #expect(doc.isLocked && doc.isReview)
        #expect(doc.reviewRows.allSatisfy { $0.isDecided })
        #expect(doc.reviewRows[2].summary == "Ship in two steps")
        #expect(doc.reviewRows[1].picks.count == 1 && doc.reviewRows[1].summary.contains(", "))
    }

    // MARK: The reply builder

    @Test func aSingleItemReplyBuildsItsItemAnswer() throws {
        let one = Self.request(items: try Self.items("question-options"))
        #expect(ReplyPayloadBuilder.itemAnswers(for: one, choice: "b", choices: nil) == [ItemAnswer(itemId: "main", choice: "b", confirmed: true)])
        let many = Self.request(items: try Self.items("options-many"))
        #expect(ReplyPayloadBuilder.itemAnswers(for: many, choice: nil, choices: ["a", "c"]) == [ItemAnswer(itemId: "main", choices: ["a", "c"], confirmed: true)])
        // A reply item's message is the answer, and an older payload has no items.
        let reply = Self.request(items: try Self.items("reply-only"))
        #expect(ReplyPayloadBuilder.itemAnswers(for: reply, choice: nil, choices: nil) == nil)
        let old = Self.request()
        #expect(ReplyPayloadBuilder.itemAnswers(for: old, choice: "a", choices: nil) == nil)
        #expect(ReplyPayloadBuilder.itemAnswers(for: one, choice: nil, choices: nil) == nil)
    }

    private func makeFlow(_ request: Case, server: FakeKnockServer, socketPath: String) async throws -> (SendFlowController, KnockClient) {
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("knock_items_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": home.path]))
        let flow = SendFlowController(
            knockCase: request, commentsStore: CommentsSessionStore(), coordinator: coordinator, draftStore: ComposerDraftStore(), onSent: {})
        return (flow, client)
    }

    private func serve(_ captured: SubmittedReply) -> (FakeKnockServer, String) {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard method == "reply.submit", let id, let reply = try? JSONDecoder().decode(SubmitParams.self, from: line).params else { return nil }
            captured.set(reply)
            return jsonRPCOK(
                id: id,
                result: #"{"id":"r_1","case_id":"\#(reply.caseId)","idempotency_key":"\#(reply.idempotencyKey)","choice":null,"message":null,"comments":[],"captures":[],"state":"queued","created_at":"2026-10-08T10:00:00Z"}"#)
        }
        return (server, socketPath)
    }

    private func waitForReply(_ captured: SubmittedReply) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while captured.value == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aDecideOnSeveralItemsSendsItemAnswersForAllOfThem() async throws {
        let captured = SubmittedReply()
        let (server, path) = serve(captured)
        defer { server.stop() }
        let request = Self.request(items: try Self.items("multi-item-degrades-for-old-app"))
        let (flow, client) = try await makeFlow(request, server: server, socketPath: path)
        var doc = QuestionsDocModel(request: request)
        let q = doc.questions
        doc.choose(q[0].points[0].choiceLabels[1], question: q[0].id, point: q[0].points[0].id)
        doc.choose(q[1].points[0].choiceLabels[0], question: q[1].id, point: q[1].points[0].id)
        doc.choose(q[1].points[0].choiceLabels[2], question: q[1].id, point: q[1].points[0].id)
        doc.setText("Ship in two steps", question: q[2].id, point: q[2].points[0].id)
        flow.sendItemAnswers(doc.itemAnswers(), message: nil)
        try await waitForReply(captured)
        let reply = try #require(captured.value)
        #expect(reply.intent == .decision)
        #expect(reply.itemAnswers?.map(\.itemId) == ["a", "b", "c"])
        #expect(reply.itemAnswers?[1].choices == ["b1", "b3"] && reply.itemAnswers?[2].text == "Ship in two steps")
        #expect(reply.answers == nil && reply.choice == nil)
        await client.stop()
    }

    @Test func leansAndRuleOutsOnSeveralItemsSendADiscussReplyWithItemSlashOptionIds() async throws {
        let captured = SubmittedReply()
        let (server, path) = serve(captured)
        defer { server.stop() }
        let request = Self.request(items: try Self.items("multi-item-degrades-for-old-app"))
        let (flow, client) = try await makeFlow(request, server: server, socketPath: path)
        var doc = QuestionsDocModel(request: request)
        let q = doc.questions
        doc.toggleLean(q[0].points[0].choiceLabels[0], question: q[0].id, point: q[0].points[0].id)
        doc.toggleRuleOut(q[0].points[0].choiceLabels[1], question: q[0].id, point: q[0].points[0].id)
        #expect(doc.sendsDiscuss)
        flow.sendItemDiscuss(leaning: doc.leaningIds, ruledOut: doc.ruledOutIds, message: "Why two?")
        try await waitForReply(captured)
        let reply = try #require(captured.value)
        #expect(reply.intent == .discuss && reply.message == "Why two?")
        #expect(reply.leaning == ["a/a1"] && reply.ruledOut == ["a/a2"])
        #expect(reply.itemAnswers == nil && reply.choice == nil)
        await client.stop()
    }

    // MARK: WAG-330: ask or keep talking from any step

    private func steppedDoc() throws -> QuestionsDocModel {
        QuestionsDocModel(request: Self.request(items: try Self.items("multi-item-degrades-for-old-app")))
    }

    @Test func textOnItemOneMakesAskThePrimaryButtonAndNextQuiet() throws {
        var doc = try steppedDoc()
        #expect(PromptBarLogic.answersPillLabels(doc: doc, comments: 0) == ["Next"])
        #expect(PromptBarLogic.answersQuietLabels(doc: doc).isEmpty)
        doc.note = "Why two?"
        #expect(doc.stepTalksNow)
        #expect(PromptBarLogic.answersPillLabels(doc: doc, comments: 0) == ["Ask"])
        #expect(PromptBarLogic.answersQuietLabels(doc: doc) == ["Next"])
        doc.next()
        #expect(PromptBarLogic.answersQuietLabels(doc: doc) == ["Back", "Next"])
    }

    @Test func aLeanOnItemOneNamesTheDiscussButtonAndSendsNow() throws {
        var doc = try steppedDoc()
        let q = doc.questions
        doc.toggleLean(q[0].points[0].choiceLabels[0], question: q[0].id, point: q[0].points[0].id)
        let labels = PromptBarLogic.answersPillLabels(doc: doc, comments: 0)
        #expect(labels.first == "Lean to 1, keep talking" && labels.last == "Lean to 1")
        #expect(PromptBarLogic.answersQuietLabels(doc: doc) == ["Next"])
        doc.toggleRuleOut(q[0].points[0].choiceLabels[1], question: q[0].id, point: q[0].points[0].id)
        #expect(PromptBarLogic.answersPillLabels(doc: doc, comments: 0).first == "Lean to 1, not 2")
    }

    @Test func nothingTypedAndNothingMarkedKeepsNext() throws {
        var doc = try steppedDoc()
        doc.choose(doc.questions[0].points[0].choiceLabels[1], question: doc.questions[0].id, point: doc.questions[0].points[0].id)
        doc.note = "   "
        #expect(!doc.stepTalksNow)
        #expect(PromptBarLogic.answersPillLabels(doc: doc, comments: 0) == ["Next"])
        #expect(PromptBarLogic.answersQuietLabels(doc: doc).isEmpty)
    }

    @Test func theLastStepStillSendsTheAnswers() throws {
        var doc = try steppedDoc()
        for question in doc.questions {
            let point = question.points[0]
            if point.select == .reply { doc.setText("Ship it", question: question.id, point: point.id) } else {
                doc.choose(point.choiceLabels[0], question: question.id, point: point.id)
            }
        }
        doc.jump(to: 3)
        #expect(doc.isReview && !doc.stepTalksNow)
        #expect(PromptBarLogic.answersPillLabels(doc: doc, comments: 0) == ["Send 3 answers"])
        #expect(PromptBarLogic.answersQuietLabels(doc: doc) == ["Back"])
    }

    @Test func askingFromItemOneSendsTheNoteWithTheAnswersSoFarAsKeepTalking() async throws {
        let captured = SubmittedReply()
        let (server, path) = serve(captured)
        defer { server.stop() }
        let request = Self.request(items: try Self.items("multi-item-degrades-for-old-app"))
        let (flow, client) = try await makeFlow(request, server: server, socketPath: path)
        var doc = QuestionsDocModel(request: request)
        let q = doc.questions
        doc.choose(q[0].points[0].choiceLabels[1], question: q[0].id, point: q[0].points[0].id)
        doc.note = "Is item 2 a must?"
        #expect(doc.stepTalksNow && !doc.sendsAnswers)
        flow.sendItemDiscuss(
            leaning: doc.leaningIds, ruledOut: doc.ruledOutIds, message: doc.message, itemAnswers: doc.itemAnswers())
        try await waitForReply(captured)
        let reply = try #require(captured.value)
        #expect(reply.intent == .discuss && reply.message == "Is item 2 a must?")
        #expect(reply.itemAnswers?.map(\.itemId) == ["a"] && reply.leaning == nil && reply.choice == nil)
        await client.stop()
    }

    @Test func aNoteAloneSendsADiscussReplyWithNoAnswers() async throws {
        let captured = SubmittedReply()
        let (server, path) = serve(captured)
        defer { server.stop() }
        let request = Self.request(items: try Self.items("multi-item-degrades-for-old-app"))
        let (flow, client) = try await makeFlow(request, server: server, socketPath: path)
        flow.sendItemDiscuss(leaning: [], ruledOut: [], message: "What is item 3?")
        try await waitForReply(captured)
        let reply = try #require(captured.value)
        #expect(reply.intent == .discuss && reply.message == "What is item 3?" && reply.itemAnswers == nil)
        await client.stop()
    }

    @Test func aDecideOnOneItemSendsItsItemAnswerAndTheOldChoice() async throws {
        let captured = SubmittedReply()
        let (server, path) = serve(captured)
        defer { server.stop() }
        let request = Self.request(items: try Self.items("question-options"))
        let single = Case(
            id: request.id, taskId: "t", kind: .question, title: "Layout?", need: "Pick.", why: "W", recommendation: "a", recommendationWhy: "R",
            options: [Option(id: "a", label: "Compact"), Option(id: "b", label: "Detailed")], status: .needsYou, hasArtifact: false,
            createdAt: "2026-10-08T10:00:00Z", updatedAt: "2026-10-08T10:00:00Z", items: request.items)
        let (flow, client) = try await makeFlow(single, server: server, socketPath: path)
        flow.composer.selectOption("b")
        flow.send()
        try await waitForReply(captured)
        let reply = try #require(captured.value)
        #expect(reply.choice == "b")
        #expect(reply.itemAnswers == [ItemAnswer(itemId: "main", choice: "b", confirmed: true)])
        await client.stop()
    }

    @Test func anOlderPayloadSendsNoItemAnswers() async throws {
        let captured = SubmittedReply()
        let (server, path) = serve(captured)
        defer { server.stop() }
        let old = Case(
            id: "c1", taskId: "t", kind: .question, title: "Layout?", need: "Pick.", why: "W", recommendation: "a", recommendationWhy: "R",
            options: [Option(id: "a", label: "Compact"), Option(id: "b", label: "Detailed")], status: .needsYou, hasArtifact: false,
            createdAt: "2026-10-08T10:00:00Z", updatedAt: "2026-10-08T10:00:00Z")
        let (flow, client) = try await makeFlow(old, server: server, socketPath: path)
        flow.composer.selectOption("b")
        flow.send()
        try await waitForReply(captured)
        let reply = try #require(captured.value)
        #expect(reply.choice == "b" && reply.itemAnswers == nil)
        await client.stop()
    }

    // MARK: The copy

    @Test func theRecommendedOptionOfAnItemIsMarkedByLabel() throws {
        let doc = QuestionsDocModel(request: Self.request(items: try Self.items("multi-item-degrades-for-old-app")))
        for point in doc.questions.flatMap(\.points) where point.select != .reply {
            #expect(point.recommended.allSatisfy { point.choiceLabels.contains($0) })
        }
        #expect(doc.questions[2].points[0].choices.isEmpty)
    }
}
