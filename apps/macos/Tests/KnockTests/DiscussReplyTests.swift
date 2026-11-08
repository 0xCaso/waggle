import Foundation
import Testing
@testable import Knock

private struct DiscussEnvelope: Decodable { let params: PendingReply }

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PendingReply?
    func set(_ value: PendingReply) { lock.lock(); stored = value; lock.unlock() }
    var value: PendingReply? { lock.lock(); defer { lock.unlock() }; return stored }
}

/// WAG-301: lean, rule out and ask on a decision ask.
@Suite(.serialized)
@MainActor
struct DiscussReplyTests {
    private let options = [
        Option(id: "a", label: "Compact layout with a sidebar", title: "Compact"),
        Option(id: "b", label: "Detailed layout with tabs", title: "Detailed"),
        Option(id: "c", label: "Wizard layout, one step at a time", title: "Wizard"),
    ]

    private func makeCase() -> Case {
        Case(
            id: "c1", taskId: "t1", kind: .question, title: "Pick a layout", need: "Need", why: "Why",
            recommendation: "a", recommendationWhy: "Because", options: options,
            status: .needsYou, hasArtifact: false,
            createdAt: "2026-10-08T10:00:00Z", updatedAt: "2026-10-08T10:00:00Z")
    }

    private func makeComposer() -> ComposerViewModel {
        ComposerViewModel(knockCase: makeCase(), draftStore: ComposerDraftStore())
    }

    private func label(
        leaning: [Int] = [], ruledOut: [Int] = [], pick: Bool = false, message: Bool = false, comments: Int = 0
    ) -> String? {
        PromptBarLogic.sendPillLabels(
            commentCount: comments, decideTitle: pick ? "Compact" : nil,
            discuss: PromptBarLogic.discussLabels(leaning: leaning, ruledOut: ruledOut),
            asks: message && !pick && leaning.isEmpty && ruledOut.isEmpty
        ).first ?? nil
    }

    // MARK: - Button label

    @Test func aPickReadsDecide() {
        #expect(label(pick: true) == "Decide")
        #expect(label(pick: true, comments: 1) == "Decide + 1 comment")
    }

    @Test func leansOnlyKeepTalking() {
        #expect(label(leaning: [1]) == "Lean to 1, keep talking")
        #expect(label(leaning: [1, 2]) == "Lean to 1 and 2, keep talking")
        #expect(label(leaning: [1, 2, 3]) == "Lean to 1, 2 and 3, keep talking")
    }

    @Test func leansAndRuleOutsNameBoth() {
        #expect(label(leaning: [1, 2], ruledOut: [3]) == "Lean to 1 and 2, not 3")
        #expect(label(leaning: [1], ruledOut: [2, 3]) == "Lean to 1, not 2 and 3")
    }

    @Test func ruleOutsOnlyKeepTalking() {
        #expect(label(ruledOut: [3]) == "Rule out 3, keep talking")
        #expect(label(ruledOut: [2, 3]) == "Rule out 2 and 3, keep talking")
    }

    @Test func textWithNoPickLeanOrRuleOutReadsAsk() {
        #expect(label(message: true) == "Ask")
        #expect(label(message: true, comments: 2) == "Ask + 2 comments")
    }

    @Test func pinnedCommentsAppendToTheDiscussLabel() {
        #expect(label(leaning: [1, 2], ruledOut: [3], comments: 1) == "Lean to 1 and 2, not 3 + 1 comment")
    }

    @Test func aNarrowRowFallsBackToShorterForms() {
        let forms = PromptBarLogic.sendPillLabels(
            commentCount: 0, discuss: PromptBarLogic.discussLabels(leaning: [1, 2], ruledOut: []), asks: false)
        #expect(forms == ["Lean to 1 and 2, keep talking", "Lean to 1 and 2"])
    }

    @Test func aPlanRoundKeepsItsStageWordsForAPickAndSaysAskOrLeanOtherwise() {
        let pick = PromptBarLogic.sendPillLabels(
            commentCount: 0, planLabel: "Next question", shortPlanLabel: "Next", decideTitle: "Compact")
        #expect(pick.first ?? nil == "Next question")
        let ask = PromptBarLogic.sendPillLabels(commentCount: 0, planLabel: "Next question", shortPlanLabel: "Next", asks: true)
        #expect(ask == ["Ask"])
        let lean = PromptBarLogic.sendPillLabels(
            commentCount: 0, planLabel: "Next question", shortPlanLabel: "Next",
            discuss: PromptBarLogic.discussLabels(leaning: [2], ruledOut: [1]))
        #expect(lean.first ?? nil == "Lean to 2, not 1")
    }

    // MARK: - Composer state

    @Test func leanAndRuleOutToggleAndSeveralRowsCanBeOn() {
        let composer = makeComposer()
        composer.toggleLean("a")
        composer.toggleLean("b")
        composer.toggleRuleOut("c")
        #expect(composer.leaningIds == ["a", "b"] && composer.ruledOutIds == ["c"])
        #expect(composer.leaningPositions == [1, 2] && composer.ruledOutPositions == [3])
        composer.toggleLean("a")
        #expect(composer.leaningIds == ["b"])
        composer.toggleRuleOut("c")
        #expect(composer.ruledOutIds.isEmpty)
    }

    @Test func aRowIsNeverLeaningAndRuledOutAtOnce() {
        let composer = makeComposer()
        composer.toggleLean("a")
        composer.toggleRuleOut("a")
        #expect(composer.leaningIds.isEmpty && composer.ruledOutIds == ["a"])
        composer.toggleLean("a")
        #expect(composer.leaningIds == ["a"] && composer.ruledOutIds.isEmpty)
    }

    @Test func aPickClearsLeansAndRuleOuts() {
        let composer = makeComposer()
        composer.toggleLean("a")
        composer.toggleRuleOut("c")
        composer.selectOption("b")
        #expect(composer.selectedOptionId == "b")
        #expect(composer.leaningIds.isEmpty && composer.ruledOutIds.isEmpty)
        #expect(composer.isDiscussing == false)
    }

    @Test func aLeanOrRuleOutClearsThePick() {
        let composer = makeComposer()
        composer.selectOption("b")
        composer.toggleLean("a")
        #expect(composer.selectedOptionId == nil && composer.leaningIds == ["a"])
        composer.selectOption("b")
        composer.toggleRuleOut("c")
        #expect(composer.selectedOptionId == nil && composer.ruledOutIds == ["c"])
    }

    @Test func aPlanRoundPickIsClearedByALean() {
        let composer = makeComposer()
        composer.selectOption("a")
        composer.toggleLean("b")
        #expect(composer.hasPick == false && composer.isDiscussing)
    }

    @Test func leansSendRatherThanAcceptTheRecommendation() {
        let composer = makeComposer()
        composer.toggleLean("b")
        #expect(composer.footerPrimaryAction == .send)
        #expect(composer.sendsDiscuss)
    }

    @Test func aNoteWithNoPickIsAQuestionAndWithAPickIsADecision() {
        let composer = makeComposer()
        composer.draftText = "Does the sidebar hide on a phone?"
        #expect(composer.sendsDiscuss)
        composer.selectOption("a")
        #expect(composer.sendsDiscuss == false)
    }

    @Test func aNewRoundOfOptionsDropsTheLeans() {
        let composer = makeComposer()
        composer.toggleLean("a")
        composer.toggleRuleOut("c")
        var updated = makeCase()
        updated = Case(
            id: "c1", taskId: "t1", kind: .question, title: "Pick a layout", need: "Need", why: "Why",
            recommendation: "a", recommendationWhy: "Because", options: Array(options.prefix(2)),
            status: .needsYou, hasArtifact: false,
            createdAt: "2026-10-08T10:00:00Z", updatedAt: "2026-10-08T10:05:00Z")
        composer.refresh(updated)
        #expect(composer.isDiscussing == false)
    }

    @Test func leansSurviveAReopenedPane() {
        let store = ComposerDraftStore()
        let first = ComposerViewModel(knockCase: makeCase(), draftStore: store)
        first.toggleLean("b")
        first.toggleRuleOut("c")
        let second = ComposerViewModel(knockCase: makeCase(), draftStore: store)
        #expect(second.leaningIds == ["b"] && second.ruledOutIds == ["c"])
    }

    @Test func aTickListHasNoLeanOrRuleOut() {
        var many = makeCase()
        many = Case(
            id: "c1", taskId: "t1", kind: .question, title: "Pick", need: "Need", why: "Why",
            recommendation: "a", recommendationWhy: "Because", options: options,
            status: .needsYou, hasArtifact: false, select: .many,
            createdAt: "2026-10-08T10:00:00Z", updatedAt: "2026-10-08T10:00:00Z")
        let composer = ComposerViewModel(knockCase: many, draftStore: ComposerDraftStore())
        composer.toggleLean("a")
        #expect(composer.supportsDiscuss == false && composer.leaningIds.isEmpty)
    }

    // MARK: - Icons

    @Test func tooltipsAndVoiceOverLabelsNameTheActionAndTheOption() {
        #expect(CalmOption.leanTip == "I lean to this, but I am not sure")
        #expect(CalmOption.ruleOutTip == "Rule this out")
        #expect(DiscussIconButton.accessibilityLabel(kind: .lean, optionTitle: "Compact") == "Lean to Compact")
        #expect(DiscussIconButton.accessibilityLabel(kind: .ruleOut, optionTitle: "Compact") == "Rule out Compact")
        #expect(CalmOption.ruledOutOpacity == 0.55)
    }

    // MARK: - Protocol

    @Test func theDiscussIntentAndItsIdsDecode() throws {
        let json = #"{"id":"r","case_id":"c1","idempotency_key":"k","comments":[],"captures":[],"intent":"discuss","leaning":["a","b"],"ruled_out":["c"],"message":"why?","state":"queued","created_at":"2026-10-08T10:00:00Z"}"#
        let reply = try JSONDecoder().decode(Reply.self, from: Data(json.utf8))
        #expect(reply.intent == .discuss && reply.leaning == ["a", "b"] && reply.ruledOut == ["c"])
    }

    @Test func theSubmitParamsEncodeLeaningAndRuledOut() throws {
        let params = ReplySubmitParams(
            caseId: "c1", idempotencyKey: "k", choice: nil, message: nil, comments: [], captures: [],
            intent: .discuss, leaning: ["a"], ruledOut: ["c"])
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [String: Any])
        #expect(object["intent"] as? String == "discuss")
        #expect(object["leaning"] as? [String] == ["a"])
        #expect(object["ruled_out"] as? [String] == ["c"])
    }

    // MARK: - What is sent

    private func sendAndCapture(_ configure: (ComposerViewModel) -> Void, act: ((SendFlowController) -> Void)? = nil) async throws -> PendingReply? {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let captured = Box()
        server.onRequest = { method, id, line in
            guard method == "reply.submit", let id,
                  let reply = try? JSONDecoder().decode(DiscussEnvelope.self, from: line).params
            else { return nil }
            captured.set(reply)
            return jsonRPCOK(
                id: id,
                result: #"{"id":"r_1","case_id":"\#(reply.caseId)","idempotency_key":"\#(reply.idempotencyKey)","comments":[],"captures":[],"state":"queued","created_at":"2026-10-08T10:00:00Z"}"#)
        }
        try server.start()
        defer { server.stop() }
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("knock_discuss_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": home.path]))
        var sent = false
        let flow = SendFlowController(
            knockCase: makeCase(), commentsStore: CommentsSessionStore(), coordinator: coordinator,
            draftStore: ComposerDraftStore(), onSent: { sent = true })
        configure(flow.composer)
        if let act { act(flow) } else { flow.send() }
        let deadline = ContinuousClock.now + .seconds(30)
        while !sent, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        await client.stop()
        return captured.value
    }

    @Test func leansAndRuleOutsGoOutAsADiscussReplyWithTheirIds() async throws {
        let sent = try await sendAndCapture { composer in
            composer.toggleLean("a")
            composer.toggleLean("b")
            composer.toggleRuleOut("c")
            composer.draftText = "Does the sidebar hide on a phone?"
        }
        #expect(sent?.intent == .discuss)
        #expect(sent?.leaning == ["a", "b"] && sent?.ruledOut == ["c"])
        #expect(sent?.choice == nil && sent?.message == "Does the sidebar hide on a phone?")
    }

    @Test func aNoteWithNoPickGoesOutAsADiscussReplyWithNoIds() async throws {
        let sent = try await sendAndCapture { $0.draftText = "Which one is cheaper?" }
        #expect(sent?.intent == .discuss && sent?.leaning == nil && sent?.ruledOut == nil)
        #expect(sent?.message == "Which one is cheaper?")
    }

    @Test func aPickStillGoesOutAsADecisionWithItsNote() async throws {
        let sent = try await sendAndCapture { composer in
            composer.selectOption("b")
            composer.draftText = "Go with tabs."
        }
        #expect(sent?.intent == .decision && sent?.choice == "b" && sent?.message == "Go with tabs.")
        #expect(sent?.leaning == nil && sent?.ruledOut == nil)
    }

    @Test func letsDiscussKeepsTalkingWithTheTypedNote() async throws {
        let sent = try await sendAndCapture({ $0.draftText = "Not sure yet." }, act: { $0.quickReply(.letsDiscuss) })
        #expect(sent?.intent == .discuss && sent?.choice == nil)
        #expect(sent?.message == "Not sure yet.\nLet's discuss")
    }

    @Test func lookAtMyCommentsIsAPlainReplyThatAsksToActOnEach() async throws {
        let sent = try await sendAndCapture({ _ in }, act: { $0.quickReply(.lookAtMyComments) })
        #expect(sent?.intent == .decision && sent?.choice == nil)
        #expect(sent?.message == "Look at my comments and act on each one.")
    }

    // MARK: - Words

    @Test func theBannerNamesWhatTheHumanDid() {
        #expect(DiscussCopy.banner(leaning: ["Compact"], ruledOut: ["Wizard"], message: "Why?") == "Leaning: Compact. Ruled out: Wizard. Why?")
        #expect(DiscussCopy.banner(leaning: [], ruledOut: [], message: nil) == "Talking it over")
    }
}
