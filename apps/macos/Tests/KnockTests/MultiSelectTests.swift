import Testing
import Foundation
@testable import Knock

private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PendingReply?
    var value: PendingReply? { lock.withLock { stored } }
    func set(_ reply: PendingReply) { lock.withLock { stored = reply } }
}

private struct Envelope: Decodable { let params: PendingReply }

/// HAIL-123: "pick several" asks.
@Suite(.serialized)
@MainActor
struct MultiSelectTests {
    private static let options = [
        Option(id: "a", label: "Fix the pinned Save button", title: "Save button"),
        Option(id: "b", label: "Add an empty state", title: "Empty state"),
        Option(id: "c", label: "Shorten the onboarding copy", title: "Onboarding copy"),
        Option(id: "d", label: "Dark mode for the chart", title: "Dark chart"),
    ]

    private static func many(max: Int? = nil, recommendations: [String] = ["a", "b"]) -> Case {
        Case(
            id: "m1", taskId: "t1", kind: .question, title: "Which fixes ship?", need: "Pick", why: "Why",
            recommendation: recommendations[0], recommendationWhy: "Cheap", options: options, status: .needsYou,
            hasArtifact: false, select: .many, max: max, recommendations: recommendations,
            createdAt: "2026-10-01T10:00:00Z", updatedAt: "2026-10-01T10:00:00Z")
    }

    private static func composer(_ item: Case = many()) -> ComposerViewModel {
        ComposerViewModel(knockCase: item, draftStore: ComposerDraftStore())
    }

    // MARK: Decoding

    @Test func aMultiSelectCaseDecodes() throws {
        let json = #"""
        {"id":"c1","task_id":"t1","kind":"question","title":"T","need":"N","why":"W","recommendation":"a",
         "recommendation_why":"R","select":"many","max":2,"recommendations":["a","c"],
         "options":[{"id":"a","label":"A"},{"id":"c","label":"C"}],"status":"needs_you","has_artifact":false,
         "latest_reply_choices":["a","c"],"created_at":"2026-10-01T10:00:00Z","updated_at":"2026-10-01T10:00:00Z"}
        """#
        let item = try JSONDecoder().decode(Case.self, from: Data(json.utf8))
        #expect(item.select == .many)
        #expect(item.max == 2)
        #expect(item.recommendations == ["a", "c"])
        #expect(item.latestReplyChoices == ["a", "c"])
    }

    @Test func anOldCaseReadsAsSingleChoice() throws {
        let json = #"""
        {"id":"c1","task_id":"t1","kind":"question","title":"T","need":"N","why":"W","recommendation":"a",
         "recommendation_why":"R","options":[{"id":"a","label":"A"}],"status":"needs_you","has_artifact":false,
         "created_at":"2026-10-01T10:00:00Z","updated_at":"2026-10-01T10:00:00Z"}
        """#
        let item = try JSONDecoder().decode(Case.self, from: Data(json.utf8))
        #expect(item.select == .one)
        #expect(item.max == nil)
        #expect(item.recommendations == ["a"])
        #expect(item.latestReplyChoices.isEmpty)
    }

    // MARK: Ticks

    @Test func recommendedOptionsArriveUnticked() {
        let composer = Self.composer()
        #expect(composer.isMultiSelect)
        #expect(composer.selectedOptionIds.isEmpty)
        #expect(!composer.hasPick)
        #expect(composer.knockCase.recommendations == ["a", "b"])
    }

    @Test func aRecommendationBeyondMaxIsNotTicked() {
        let composer = Self.composer(Self.many(max: 1))
        composer.tickRecommended()
        #expect(composer.selectedOptionIds == ["a"])
    }

    @Test func keysToggleTheRowsAndKeepOptionOrder() {
        let composer = Self.composer()
        composer.tickRecommended()
        composer.selectOption(atPosition: 4)
        #expect(composer.selectedOptionIds == ["a", "b", "d"])
        composer.selectOption(atPosition: 1)
        #expect(composer.selectedOptionIds == ["b", "d"])
        composer.selectOption(atPosition: 9)
        #expect(composer.selectedOptionIds == ["b", "d"])
    }

    @Test func atTheLimitAnUntickedRowDoesNotToggle() {
        let composer = Self.composer(Self.many(max: 2))
        composer.tickRecommended()
        #expect(composer.isAtLimit)
        #expect(!composer.canToggle("c"))
        composer.toggleOption("c")
        #expect(composer.selectedOptionIds == ["a", "b"])
        #expect(composer.canToggle("a"))
        composer.toggleOption("a")
        #expect(composer.selectedOptionIds == ["b"])
        #expect(!composer.isAtLimit)
        composer.toggleOption("c")
        #expect(composer.selectedOptionIds == ["b", "c"])
    }

    @Test func clearUntickseverything() {
        let composer = Self.composer()
        composer.clearPicks()
        #expect(composer.selectedOptionIds.isEmpty)
        #expect(!composer.hasPick)
    }

    @Test func aDraftKeepsItsTicksIncludingNone() {
        let store = ComposerDraftStore()
        let first = ComposerViewModel(knockCase: Self.many(), draftStore: store)
        first.clearPicks()
        first.toggleOption("c")
        let again = ComposerViewModel(knockCase: Self.many(), draftStore: store)
        #expect(again.selectedOptionIds == ["c"])
        again.clearPicks()
        let third = ComposerViewModel(knockCase: Self.many(), draftStore: store)
        #expect(third.selectedOptionIds.isEmpty)
    }

    @Test func aSingleChoiceAskIsUnchanged() {
        let item = Case(
            id: "s1", taskId: "t1", kind: .question, title: "T", need: "N", why: "W", recommendation: "a",
            recommendationWhy: "R", options: Self.options, status: .needsYou, hasArtifact: false,
            createdAt: "2026-10-01T10:00:00Z", updatedAt: "2026-10-01T10:00:00Z")
        let composer = ComposerViewModel(knockCase: item, draftStore: ComposerDraftStore())
        #expect(!composer.isMultiSelect)
        #expect(composer.selectedOptionIds.isEmpty)
        composer.selectOption("b")
        #expect(composer.selectedOptionId == "b")
        #expect(composer.currentChoice == "b")
        #expect(composer.currentChoices == nil)
    }

    // MARK: What gets sent

    @Test func theTicksAreTheChoices() {
        let composer = Self.composer()
        composer.tickRecommended()
        #expect(composer.currentChoices == ["a", "b"])
        #expect(composer.currentChoice == nil)
        #expect(composer.footerPrimaryAction == .sendPicks(count: 2))
        #expect(ComposerViewModel.primaryButtonLabel(action: .sendPicks(count: 2), commentCount: 0) == "Send 2")
    }

    @Test func noTicksNeedANoteToBeAnEmptyList() {
        let composer = Self.composer()
        composer.clearPicks()
        #expect(composer.currentChoices == nil)
        composer.draftText = "None of these"
        #expect(composer.currentChoices == [])
    }

    @Test func sendPillSaysHowManyAreTicked() {
        #expect(PromptBarLogic.sendPillLabel(commentCount: 0, pickCount: 2) == "Send 2")
        #expect(PromptBarLogic.sendPillLabel(commentCount: 1, pickCount: 2) == "Send 2 + 1 comment")
        #expect(PromptBarLogic.sendPillLabel(commentCount: 0, pickCount: 0) == nil)
        #expect(PromptBarLogic.sendPillLabel(commentCount: 2) == "Send + 2 comments")
    }

    @Test func paramsCarryChoices() throws {
        let params = ReplySubmitParams(
            caseId: "m1", idempotencyKey: "k", choice: nil, message: nil, comments: [], captures: [],
            intent: .decision, choices: ["a", "c"])
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [String: Any])
        #expect(object["choices"] as? [String] == ["a", "c"])
        let single = ReplySubmitParams(
            caseId: "m1", idempotencyKey: "k", choice: "a", message: nil, comments: [], captures: [], intent: .decision)
        let plain = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(single)) as? [String: Any])
        #expect(plain["choices"] == nil)
    }

    @Test func aPendingReplyKeepsItsChoices() throws {
        let reply = PendingReply(
            caseId: "m1", idempotencyKey: "k", choice: nil, message: nil, comments: [], captures: [], choices: ["a"])
        let back = try JSONDecoder().decode(PendingReply.self, from: JSONEncoder().encode(reply))
        #expect(back.choices == ["a"])
    }

    @Test func sendingGoesToReplySubmitWithChoices() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let captured = Captured()
        server.onRequest = { method, id, line in
            guard method == "reply.submit", let id, let reply = try? JSONDecoder().decode(Envelope.self, from: line).params
            else { return nil }
            captured.set(reply)
            return jsonRPCOK(
                id: id,
                result: #"{"id":"r_1","case_id":"\#(reply.caseId)","idempotency_key":"\#(reply.idempotencyKey)","choices":["a","c"],"comments":[],"captures":[],"state":"queued","created_at":"2026-10-01T10:00:00Z"}"#
            )
        }
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        defer { server.stop() }

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("knock_multi_\(UUID().uuidString)").path
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": home]))
        let flow = SendFlowController(
            knockCase: Self.many(), commentsStore: CommentsSessionStore(), coordinator: coordinator,
            draftStore: ComposerDraftStore(), onSent: {})
        flow.composer.tickRecommended()
        flow.composer.toggleOption("b")
        flow.composer.toggleOption("c")
        flow.send()
        _ = try await pollUntil(.seconds(20)) { captured.value != nil }

        #expect(captured.value?.choices == ["a", "c"])
        #expect(captured.value?.choice == nil)
        #expect(flow.pendingReplyValue == "Save button, Onboarding copy")
        await client.stop()
    }

    // MARK: Copy

    @Test func dockAndDecisionCopy() {
        #expect(MultiSelectCopy.decisionHead(max: nil) == "Decision · pick any")
        #expect(MultiSelectCopy.decisionHead(max: 2) == "Decision · pick up to 2")
        #expect(MultiSelectCopy.dockLabel(count: 2, max: nil) == "Pick any · 2 selected")
        #expect(MultiSelectCopy.dockLabel(count: 0, max: nil) == "Pick any")
        #expect(MultiSelectCopy.dockLabel(count: 0, max: 2) == "Pick up to 2")
        #expect(MultiSelectCopy.dockLabel(count: 2, max: 2) == "Pick up to 2 · 2 of 2")
        #expect(MultiSelectCopy.isAtLimit(count: 2, max: 2))
        #expect(!MultiSelectCopy.isAtLimit(count: 9, max: nil))
        #expect(DecisionSectionView.title(multi: .init(max: 2, recommendedIds: ["a"])) == "Decision · pick up to 2")
        #expect(DecisionSectionView.title() == "Decision")
    }

    @Test func theSentCardListsTheChosenTitles() {
        let item = Case(
            id: "m1", taskId: "t1", kind: .question, title: "T", need: "N", why: "W", recommendation: "a",
            recommendationWhy: "R", options: Self.options, status: .waitingOnAgent, hasArtifact: false,
            latestReplyId: "r1", latestReplyState: .queued, latestReplyAt: "2026-10-01T10:05:00Z",
            latestReplyChoices: ["a", "c"], select: .many,
            createdAt: "2026-10-01T10:00:00Z", updatedAt: "2026-10-01T10:05:00Z")
        let answer = SentAnswerCopy.answer(for: item)
        #expect(answer.label == "YOU PICKED")
        #expect(answer.title == "1 · Save button\n3 · Onboarding copy")
        #expect(item.answeredSummaryLine == "you → Save button, Onboarding copy")
    }
}
