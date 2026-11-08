import AppKit
import Foundation
import Testing
@testable import Knock

private struct ManyEnvelope: Decodable { let params: PendingReply }

private final class ManyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PendingReply?
    func set(_ value: PendingReply) { lock.lock(); stored = value; lock.unlock() }
    var value: PendingReply? { lock.lock(); defer { lock.unlock() }; return stored }
}

/// WAG-329: a pick-many ask shows the single-ask rows and never starts with options ticked.
@Suite(.serialized)
@MainActor
struct ManyPickTests {
    private static let options = [
        Option(id: "a", label: "Fix the pinned Save button", title: "Save button"),
        Option(id: "b", label: "Add an empty state", title: "Empty state"),
        Option(id: "c", label: "Shorten the onboarding copy", title: "Onboarding copy"),
    ]

    private static func many(max: Int? = nil, options: [Option] = ManyPickTests.options) -> Case {
        Case(
            id: "m1", taskId: "t1", kind: .question, title: "Which fixes ship?", need: "Pick", why: "Why",
            recommendation: "a", recommendationWhy: "Cheap", options: options, status: .needsYou,
            hasArtifact: false, select: .many, max: max, recommendations: ["a", "c"],
            createdAt: "2026-10-09T10:00:00Z", updatedAt: "2026-10-09T10:00:00Z")
    }

    private func tempHome() -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("knock_manypick_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func sent(
        comments: Int = 0, note: String? = nil, expectsReply: Bool = true, act: (SendFlowController) -> Void
    ) async throws -> PendingReply? {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let box = ManyBox()
        server.onRequest = { method, id, line in
            guard method == "reply.submit", let id,
                  let reply = try? JSONDecoder().decode(ManyEnvelope.self, from: line).params
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
        if comments > 0 {
            store.addCapture(image: NSImage(size: NSSize(width: 10, height: 10)), revision: 1)
            for i in 0..<comments {
                store.beginDraft(rect: Rect(x: 0.1, y: 0.1 + Double(i) * 0.2, w: 0.2, h: 0.1))
                store.updateDraftText("fix \(i)")
                store.commitDraft()
            }
        }
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        let flow = SendFlowController(
            knockCase: Self.many(), commentsStore: store, coordinator: coordinator, draftStore: ComposerDraftStore(), onSent: {})
        if let note { flow.composer.draftText = note }
        act(flow)
        let deadline = ContinuousClock.now + (expectsReply ? .seconds(15) : .milliseconds(600))
        while box.value == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        await client.stop()
        return box.value
    }

    // MARK: - No pre-ticks

    @Test func nothingIsTickedOnLoadAndTheRecommendationIsOnlyMarked() {
        let composer = ComposerViewModel(knockCase: Self.many(), draftStore: ComposerDraftStore())
        #expect(composer.selectedOptionIds.isEmpty && !composer.hasPick)
        #expect(composer.knockCase.recommendations == ["a", "c"])
        #expect(composer.currentChoices == nil)
    }

    @Test func aNewRoundStartsUnticked() {
        let composer = ComposerViewModel(knockCase: Self.many(), draftStore: ComposerDraftStore())
        composer.toggleOption("b")
        composer.refresh(Self.many(options: Array(Self.options.reversed())))
        #expect(composer.selectedOptionIds.isEmpty)
        composer.tickRecommended()
        composer.reset()
        #expect(composer.selectedOptionIds.isEmpty)
    }

    @Test func tickTheRecommendedTicksThemAsThePersonsOwn() {
        let composer = ComposerViewModel(knockCase: Self.many(), draftStore: ComposerDraftStore())
        #expect(composer.canTickRecommended)
        composer.tickRecommended()
        #expect(composer.selectedOptionIds == ["a", "c"])
        #expect(!composer.canTickRecommended)
    }

    @Test func theHeaderCountsOnlyAfterATick() {
        #expect(MultiSelectCopy.dockLabel(count: 0, max: nil) == "Pick any")
        #expect(MultiSelectCopy.dockLabel(count: 0, max: 3) == "Pick up to 3")
        #expect(MultiSelectCopy.dockLabel(count: 2, max: nil) == "Pick any · 2 selected")
    }

    // MARK: - The button

    @Test func buttonStates() {
        #expect(PromptBarLogic.sendPillLabels(commentCount: 0, pickCount: 2, isMany: true) == ["Decide: 2 picked"])
        #expect(PromptBarLogic.sendPillLabels(commentCount: 1, pickCount: 2, isMany: true) == ["Decide: 2 picked + 1 comment", "Decide: 2 picked"])
        #expect(PromptBarLogic.sendPillLabels(commentCount: 2, pickCount: 0, asks: false, sendsComments: true, isMany: true) == ["Send comments"])
        #expect(PromptBarLogic.sendPillLabels(commentCount: 0, pickCount: 0, asks: true, isMany: true) == ["Ask"])
        #expect(PromptBarLogic.sendLabel == "Send")
        #expect(!PromptBarLogic.canSend(hasChoice: false, hasMessage: false, commentCount: 0))
    }

    // MARK: - What goes out

    @Test func ticksAreADecisionMarkedConfirmed() async throws {
        let reply = try #require(try await sent { $0.composer.tickRecommended(); $0.send() })
        #expect(reply.intent == .decision)
        #expect(reply.choices == ["a", "c"])
        // An ask with no items sends the plain choices: only a pick the person made reaches them.
        #expect(reply.itemAnswers == nil)
    }

    @Test func aManyItemAnswerCarriesTheConfirmedMarker() {
        let item = Item(
            id: "main", question: "Which fixes ship?", select: .many, options: Self.options, recommendation: ["a", "c"])
        var request = Self.many()
        request = Case(
            id: "m2", taskId: "t1", kind: .question, title: "T", need: "N", why: "W", recommendation: "", recommendationWhy: "",
            options: [], status: .needsYou, hasArtifact: false, createdAt: request.createdAt, updatedAt: request.updatedAt,
            items: [item])
        #expect(
            ReplyPayloadBuilder.itemAnswers(for: request, choice: nil, choices: ["a", "c"])
                == [ItemAnswer(itemId: "main", choices: ["a", "c"], confirmed: true)])
    }

    @Test func aNoteWithNoTickKeepsTalking() async throws {
        let reply = try #require(try await sent(note: "why these two?") { $0.send() })
        #expect(reply.intent == .discuss && reply.choices == nil && reply.itemAnswers == nil)
        #expect(reply.message == "why these two?")
    }

    @Test func commentsWithNoTickKeepTalking() async throws {
        let reply = try #require(try await sent(comments: 2) { $0.send() })
        #expect(reply.intent == .discuss && reply.choices == nil && reply.itemAnswers == nil)
        #expect(reply.comments.count == 2)
    }

    @Test func sendWithNothingSendsNothing() async throws {
        let reply = try await sent(expectsReply: false) { $0.send() }
        #expect(reply == nil)
    }
}
