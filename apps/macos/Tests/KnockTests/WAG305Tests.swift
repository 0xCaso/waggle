import Testing
import Foundation
@testable import Knock

private struct Wag305Envelope: Decodable { let params: PendingReply }

private final class Wag305Box: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ""
    var value: String { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ text: String) { lock.lock(); stored = text; lock.unlock() }
}

/// One composer (WAG-305): one placeholder per mode, the button words of the steps bar, and the
/// questions branch of the workspace column.
struct WAG305Tests {
    private func point(_ id: String) -> QuestionPoint {
        QuestionPoint(id: id, text: "P \(id)", options: [PointOption(label: "One"), PointOption(label: "Two")])
    }

    private func ask(questionCount: Int, options: [Option] = []) -> Case {
        let questions = (1...max(questionCount, 1)).map {
            Question(id: "q\($0)", title: "Question \($0)", now: nil, points: [point("p")], artifactRef: nil, variants: nil, variantLabel: nil)
        }
        return Case(
            id: "c1", taskId: "t", kind: .question, title: "Which layout?", need: "Pick.", why: "Cannot decide.",
            recommendation: "", recommendationWhy: "", options: options, status: .needsYou, hasArtifact: false,
            createdAt: "2026-10-08T10:00:00Z", updatedAt: "2026-10-08T10:00:00Z", artifactKind: nil,
            questions: questionCount == 0 ? [] : questions)
    }

    // MARK: Placeholders

    @Test func oneTextPerMode() {
        #expect(PromptBarLogic.placeholder(.decide) == "Add a note, or ask something…")
        #expect(PromptBarLogic.placeholder(.reply) == "Reply in your own words…")
        #expect(PromptBarLogic.placeholder(.steps) == "Add a note, or ask something…")
        #expect(PromptBarLogic.placeholder(.revision) == "Add a comment, or reply…")
    }

    @Test func noPlaceholderHasAnEmDashOrTheOldWords() {
        for mode in [PromptBarLogic.PlaceholderMode.decide, .reply, .steps, .revision] {
            let text = PromptBarLogic.placeholder(mode)
            #expect(!text.contains("—") && !text.contains("(optional)"))
        }
    }

    @Test func theCaseModePicksThePlaceholder() {
        #expect(PromptBarLogic.placeholder(for: .decide, hasRevision: false) == "Add a note, or ask something…")
        #expect(PromptBarLogic.placeholder(for: .reply, hasRevision: false) == "Reply in your own words…")
        #expect(PromptBarLogic.placeholder(for: .answers, hasRevision: false) == "Add a note, or ask something…")
        #expect(PromptBarLogic.placeholder(for: .decide, hasRevision: true) == "Add a comment, or reply…")
        #expect(PromptBarLogic.placeholder(for: .reply, hasRevision: true) == "Add a comment, or reply…")
    }

    // MARK: Button words

    @Test func theStepsButtonSaysNextThenSends() {
        var doc = QuestionsDocModel(request: ask(questionCount: 3))
        #expect(PromptBarLogic.answersPillLabels(doc: doc, comments: 0) == ["Next"])
        #expect(PromptBarLogic.answersQuietLabels(doc: doc).isEmpty)
        doc.next()
        #expect(PromptBarLogic.answersPillLabels(doc: doc, comments: 0) == ["Next"])
        #expect(PromptBarLogic.answersQuietLabels(doc: doc) == ["Back"])
        doc.next()
        #expect(PromptBarLogic.answersPillLabels(doc: doc, comments: 0) == ["Review and send"])
        doc.next()
        #expect(doc.isReview)
        #expect(PromptBarLogic.answersPillLabels(doc: doc, comments: 0) == ["Send answers"])
    }

    @Test func pinnedCommentsOnAStepSendNowAndNextGoesQuiet() {
        var doc = QuestionsDocModel(request: ask(questionCount: 3))
        #expect(doc.stepTalksNow(comments: 1))
        #expect(PromptBarLogic.answersPillLabels(doc: doc, comments: 1) == ["Send comments"])
        #expect(PromptBarLogic.answersQuietLabels(doc: doc, comments: 1) == ["Next"])
        doc.next()
        #expect(PromptBarLogic.answersQuietLabels(doc: doc, comments: 2) == ["Back", "Next"])
        doc.jump(to: 3)
        #expect(doc.isReview && !doc.stepTalksNow(comments: 2))
    }

    @Test func theSendButtonCountsAnswersAndComments() {
        var doc = QuestionsDocModel(request: ask(questionCount: 2))
        doc.choose("One", question: "q1", point: "p")
        doc.jump(to: 2)
        #expect(PromptBarLogic.answersPillLabels(doc: doc, comments: 0) == ["Send 1 answer"])
        #expect(PromptBarLogic.answersPillLabels(doc: doc, comments: 2) == ["Send 1 answer + 2 comments", "Send 1 answer"])
    }

    // MARK: Layout

    @Test func anEmptyFieldKeepsOneRowWithTheButtonWhateverTheLabel() {
        let controls = PromptBarLogic.controlsWidth(quietLabels: ["Ask for more detail"], sendPillLabel: "Decide")
        // The shared-row rule (the answer box keeps its own row since 2026-11-10; the 14 pt tools gap needs a wider bar).
        #expect(!PromptBarLogic.fieldTakesOwnRow(text: "", naturalTextWidth: 0, barWidth: 480, controlsWidth: controls))
        #expect(PromptBarLogic.contentHeight(usedTextHeight: 0) == 28)
    }

    @Test func theControlsPlanGivesWayBeforeTheButton() {
        let plan = PromptBarLogic.controlsPlan(rowWidth: 300, quietLabels: ["Ask for more detail"], pillLabels: ["Lean to 1 and 2, keep talking", "Lean to 1 and 2"])
        #expect(plan.overflowLabels == ["Ask for more detail"])
        #expect(plan.sendPillLabel != nil)
    }

    // MARK: Workspace questions branch

    @Test func aMultiQuestionAskShowsItsStepsInTheWorkspace() {
        #expect(AskPanelLayout.showsQuestions(ask(questionCount: 3)))
        #expect(!AskPanelLayout.showsQuestions(ask(questionCount: 0)))
        #expect(!AskPanelLayout.showsPickBlock(ask(questionCount: 3)))
    }

    @Test @MainActor func theWorkspaceControllerOpensOnStepOneAndTheReviewStep() {
        let controller = AskDocController(client: KnockClient(socketPath: "/tmp/knock-test-none.sock"), request: ask(questionCount: 3))
        #expect(controller.doc?.isStepped == true)
        #expect(controller.doc?.currentQuestion?.id == "q1")
        controller.doc?.jump(to: 3)
        #expect(controller.doc?.isReview == true)
        #expect(controller.doc?.reviewRows.count == 3)
    }

    @Test @MainActor func theWorkspaceSharesItsAnswersWithThePane() {
        let memory = AskDocMemory()
        let client = KnockClient(socketPath: "/tmp/knock-test-none.sock")
        let item = ask(questionCount: 2)
        let workspace = AskDocController(client: client, request: item, store: memory)
        workspace.doc?.choose("Two", question: "q2", point: "p")
        let pane = AskDocController(client: client, request: item, store: memory)
        #expect(pane.doc?.answers() == [PointAnswer(questionId: "q2", pointId: "p", choice: "Two", note: nil)])
    }
}

@Suite(.serialized)
@MainActor
struct WAG305SendTests {
    fileprivate nonisolated static func handler(_ captured: Wag305Box) -> ((String, Int?, Data) -> Data?) {
        return { method, id, line in
            guard method == "reply.submit", let id,
                  let reply = try? JSONDecoder().decode(Wag305Envelope.self, from: line).params
            else { return nil }
            let answers = (reply.answers ?? []).map { "\($0.questionId).\($0.pointId)=\($0.choice)/\($0.note ?? "-")" }.joined(separator: ";")
            captured.set("choice=\(reply.choice ?? "nil") answers=\(answers) message=\(reply.message ?? "nil")")
            return jsonRPCOK(
                id: id,
                result: #"{"id":"r_1","case_id":"\#(reply.caseId)","idempotency_key":"\#(reply.idempotencyKey)","choice":null,"message":null,"comments":[],"captures":[],"state":"queued","created_at":"2026-10-08T10:00:00Z"}"#
            )
        }
    }

    private func ask() -> Case {
        let questions = (1...2).map {
            Question(id: "q\($0)", title: "Question \($0)", now: nil, points: [QuestionPoint(id: "p", text: "P", options: [PointOption(label: "One"), PointOption(label: "Two")])], artifactRef: nil, variants: nil, variantLabel: nil)
        }
        return Case(
            id: "c1", taskId: "t", kind: .question, title: "Which layout?", need: "Pick.", why: "Cannot decide.",
            recommendation: "", recommendationWhy: "", options: [], status: .needsYou, hasArtifact: false,
            createdAt: "2026-10-08T10:00:00Z", updatedAt: "2026-10-08T10:00:00Z", artifactKind: nil, questions: questions)
    }

    @Test func sendingFromTheWorkspaceSendsTheAnswers() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let captured = Wag305Box()
        server.onRequest = Self.handler(captured)
        try server.start()
        defer { server.stop() }
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let home = NSTemporaryDirectory() + "knock-" + UUID().uuidString.prefix(6)
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": home]))
        var sent = 0
        let item = ask()
        let flow = SendFlowController(
            knockCase: item, commentsStore: CommentsSessionStore(), coordinator: coordinator,
            draftStore: ComposerDraftStore(), onSent: { sent += 1 })
        var doc = QuestionsDocModel(request: item)
        doc.choose("One", question: "q1", point: "p")
        doc.note = "Keep it short"

        // What the steps bar's button does on the review step: the same call the pane makes.
        flow.sendAnswers(doc.answers(), message: doc.message)
        _ = try await pollUntil(.seconds(20)) { sent != 0 }

        #expect(sent == 1)
        #expect(captured.value == "choice=nil answers=q1.p=One/- message=Keep it short")
        await client.stop()
    }
}
