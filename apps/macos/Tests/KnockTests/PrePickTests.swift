import AppKit
import Foundation
import Testing
@testable import Knock

private struct PrePickEnvelope: Decodable { let params: PendingReply }

private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PendingReply?
    func set(_ value: PendingReply) { lock.lock(); stored = value; lock.unlock() }
    var value: PendingReply? { lock.lock(); defer { lock.unlock() }; return stored }
}

/// WAG-328: a pre-selected recommendation is a suggestion. It becomes a choice only after the person's own act.
@Suite(.serialized)
@MainActor
struct PrePickTests {
    private func tempHome() -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("knock_prepick_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func planCase() throws -> Case {
        var json = ItemsDecodeTests.caseJSON(extra: [
            "kind": "question", "recommendation": "a", "recommendation_why": "Fastest.", "status": "needs_you",
            "options": [["id": "a", "label": "Compact"], ["id": "b", "label": "Detailed"]],
            "plan": ["stage": ["name": "approaches", "step": 1, "total": 2], "rounds": 2, "answered": 1],
        ])
        json["has_artifact"] = true
        return try JSONDecoder().decode(Case.self, from: ItemsDecodeTests.data(json))
    }

    /// A plain question with a recommendation and no plan: nothing is preselected.
    private func questionCase() throws -> Case {
        let json = ItemsDecodeTests.caseJSON(extra: [
            "kind": "question", "recommendation": "b", "recommendation_why": "Safer.", "status": "needs_you",
            "options": [["id": "a", "label": "Compact"], ["id": "b", "label": "Detailed"]],
        ])
        return try JSONDecoder().decode(Case.self, from: ItemsDecodeTests.data(json))
    }

    private func pinComments(_ store: CommentsSessionStore, count: Int) {
        store.addCapture(image: NSImage(size: NSSize(width: 10, height: 10)), revision: 1)
        for i in 0..<count {
            store.beginDraft(rect: Rect(x: 0.1, y: 0.1 + Double(i) * 0.2, w: 0.2, h: 0.1))
            store.updateDraftText("fix \(i)")
            store.commitDraft()
        }
    }

    /// Sends through a flow and returns the reply the daemon would receive (nil when nothing went out).
    private func sent(
        _ request: Case, comments: Int = 0, note: String? = nil, expectsReply: Bool = true, act: (SendFlowController) -> Void
    ) async throws -> PendingReply? {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let box = ReplyBox()
        server.onRequest = { method, id, line in
            guard method == "reply.submit", let id,
                  let reply = try? JSONDecoder().decode(PrePickEnvelope.self, from: line).params
            else { return nil }
            box.set(reply)
            return jsonRPCOK(
                id: id,
                result: #"{"id":"r_1","case_id":"\#(reply.caseId)","idempotency_key":"\#(reply.idempotencyKey)","choice":null,"message":null,"comments":[],"captures":[],"state":"queued","created_at":"2026-10-09T10:00:00Z"}"#)
        }
        try server.start()
        defer { server.stop() }
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        let store = CommentsSessionStore()
        if comments > 0 { pinComments(store, count: comments) }
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        let flow = SendFlowController(
            knockCase: request, commentsStore: store, coordinator: coordinator, draftStore: ComposerDraftStore(), onSent: {})
        if let note { flow.composer.draftText = note }
        act(flow)
        // Wait for the reply, never a fixed time (a loaded suite is slow); give up after 15 s. When nothing should
        // go out, wait a short while to show that nothing did.
        let deadline = ContinuousClock.now + (expectsReply ? .seconds(15) : .milliseconds(600))
        while box.value == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        await client.stop()
        return box.value
    }

    // MARK: - The reply

    @Test func commentsOverAPrePickSendKeepTalkingWithNoChoice() async throws {
        let reply = try #require(try await sent(try planCase(), comments: 2) { $0.send() })
        #expect(reply.intent == .discuss)
        #expect(reply.choice == nil)
        #expect(reply.itemAnswers == nil)
        #expect(reply.comments.count == 2)
    }

    @Test func commentsOverNoPickSendKeepTalkingNotTheRecommendation() async throws {
        // c_98182bd7: four comments, no pick, delivered as the recommendation.
        let reply = try #require(try await sent(try questionCase(), comments: 4) { $0.send() })
        #expect(reply.intent == .discuss && reply.choice == nil && reply.itemAnswers == nil)
    }

    @Test func aNoteOverAPrePickSendsKeepTalking() async throws {
        let reply = try #require(try await sent(try planCase(), note: "what about cost?") { $0.send() })
        #expect(reply.intent == .discuss && reply.choice == nil && reply.message == "what about cost?")
    }

    @Test func sendWithOnlyAPrePickSendsNothing() async throws {
        let reply = try await sent(try planCase(), expectsReply: false) { $0.send() }
        #expect(reply == nil)
    }

    @Test func anExplicitClickThenSendIsTheDecision() async throws {
        let reply = try #require(try await sent(try planCase()) { $0.composer.selectOption("b"); $0.send() })
        #expect(reply.intent == .decision && reply.choice == "b")
    }

    @Test func clickingThePrePickedRowItselfClearsIt() async throws {
        // Nothing is pre-picked (WAG-336): a click on the recommended row is the person's own pick.
        let flow = try await sent(try planCase(), comments: 1) { $0.composer.selectOption("a"); $0.send() }
        #expect(flow?.choice == "a")
    }

    // MARK: - The composer

    @Test func aPlanRoundIsNeverPrePicked() throws {
        let composer = ComposerViewModel(knockCase: try planCase(), draftStore: ComposerDraftStore())
        #expect(composer.selectedOptionId == nil && !composer.hasPrePick)
        #expect(composer.currentChoice == nil && !composer.hasPick)
        #expect(!composer.isPrePickOnly(commentCount: 0))
        composer.draftText = "a note"
        #expect(composer.sendsDiscuss)
        composer.draftText = ""
        composer.selectOption("a")
        #expect(composer.currentChoice == "a" && composer.hasPick)
    }

    @Test func aPlanRoundWithNothingToSendShowsThePlainArrow() {
        #expect(PromptBarLogic.plansBareArrow(isPlanRound: true, hasOptions: true, canSend: false))
        #expect(!PromptBarLogic.plansBareArrow(isPlanRound: true, hasOptions: true, canSend: true))
        #expect(!PromptBarLogic.plansBareArrow(isPlanRound: false, hasOptions: true, canSend: false))
    }

    @Test func aKeyPickIsExplicit() throws {
        let composer = ComposerViewModel(knockCase: try planCase(), draftStore: ComposerDraftStore())
        composer.selectOption(atPosition: 2)
        #expect(composer.currentChoice == "b" && composer.hasPick)
        // The recommended row's own key picks it; pressing it again takes the pick away.
        let again = ComposerViewModel(knockCase: try planCase(), draftStore: ComposerDraftStore())
        again.selectOption(atPosition: 1)
        #expect(again.currentChoice == "a")
        again.selectOption(atPosition: 1)
        #expect(again.currentChoice == nil)
    }

    // MARK: - The button title

    @Test func theButtonTitleMatchesWhatIsSent() throws {
        let composer = ComposerViewModel(knockCase: try planCase(), draftStore: ComposerDraftStore())
        // Only the pre-pick: the title names the option.
        #expect(PromptBarLogic.prePickPillLabels(title: "Compact").first ?? nil == "Decide: Compact")
        // Comments over the pre-pick: "Send comments", and it sends Keep talking.
        #expect(PromptBarLogic.sendPillLabels(commentCount: 2, planLabel: "Next question", sendsComments: true) == ["Send comments"])
        // A note over the pre-pick: "Ask", and it sends Keep talking.
        #expect(!composer.hasPick)
        composer.draftText = "why?"
        #expect(composer.sendsDiscuss)
        #expect(PromptBarLogic.sendPillLabels(commentCount: 0, planLabel: "Next question", asks: composer.sendsDiscuss) == ["Ask"])
        // An explicit pick: the plan words, and it sends the decision.
        composer.draftText = ""
        composer.selectOption("b")
        #expect(!composer.sendsDiscuss && composer.currentChoice == "b")
    }
}
