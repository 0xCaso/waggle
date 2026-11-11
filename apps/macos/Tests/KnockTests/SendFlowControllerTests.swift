import Testing
import AppKit
import Foundation
@testable import Knock

private struct SubmitEnvelope: Decodable { let params: PendingReply }
private struct ReplaceCommentsEnvelope: Decodable {
    struct Params: Decodable { let comments: [Knock.Comment] }
    let params: Params
}

/// `SendFlowController`: the review-before-send gate (docs/design/mvp-
/// values.md §M6 - "With comments present, Send first shows the review
/// step"), and that a plain send with nothing to review goes straight
/// through.
///
/// `.serialized`: each test starts its own real `FakeKnockServer`/`KnockClient`
/// pair (see `SendCoordinatorTests`'s note) - one at a time avoids the
/// socket/thread pile-up that made the suite hang intermittently.
@Suite(.serialized)
@MainActor
struct SendFlowControllerTests {
    /// Waits for a condition, never for a fixed time: a loaded suite is slow. Gives up after 30 s
    /// and lets the test's own expectation report the failure.
    private func waitForSend(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func tempHome() -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("knock_flow_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// A real, drawable 10x10 image whose `pngData()` actually encodes -
    /// unlike a bare `NSImage(size:)` with nothing drawn into it, which
    /// AppKit's PNG encoder refuses (see `AnnotatedCaptureRendererTests.
    /// solidImage` for the same `lockFocus`-avoidance note). Needed here
    /// because a restored capture round-trips through real base64 PNG bytes,
    /// not just a bare `NSImage` reference the way a live Comment-mode
    /// capture does.
    private func solidImage(size: NSSize = NSSize(width: 10, height: 10)) -> NSImage {
        let width = Int(size.width), height = Int(size.height)
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        return NSImage(cgImage: context.makeImage()!, size: size)
    }

    private func optionsCase() -> Case {
        Case(
            id: "c1", taskId: "t1", kind: .review, title: "Layout",
            need: "Pick one", why: "Not a technical call",
            recommendation: "a", recommendationWhy: "It is faster",
            options: [Option(id: "a", label: "A · Compact"), Option(id: "b", label: "B · Detailed")],
            status: .needsYou, hasArtifact: true,
            createdAt: "2026-09-26T10:00:00Z", updatedAt: "2026-09-26T10:00:00Z"
        )
    }

    /// A question ask with options and no artifact (docs/design/mvp-values.md
    /// §M7 Panel A), as the case pane shows it (docs/stories/HAIL-25.md).
    private func questionCase() -> Case {
        Case(
            id: "c2", taskId: "t1", kind: .question, title: "Rarity weights for the first pack",
            need: "Pick a split", why: "A product call, not a technical one",
            recommendation: "seventy", recommendationWhy: "Matches the playtest's pull rates",
            options: [Option(id: "seventy", label: "70/25/5"), Option(id: "sixty", label: "60/30/10")],
            status: .needsYou, hasArtifact: false,
            createdAt: "2026-09-26T10:00:00Z", updatedAt: "2026-09-26T10:00:00Z"
        )
    }

    /// A question ask that already has a queued reply for this round
    /// (docs/stories/HAIL-34.md, operator decision on case c_c548e66e…) -
    /// `beginChangingAnswer()`'s prefill source.
    private func answeredQuestionCase() -> Case {
        Case(
            id: "c3", taskId: "t1", kind: .question, title: "Rarity weights for the first pack",
            need: "Pick a split", why: "A product call, not a technical one",
            recommendation: "seventy", recommendationWhy: "Matches the playtest's pull rates",
            options: [Option(id: "seventy", label: "70/25/5"), Option(id: "sixty", label: "60/30/10")],
            status: .waitingOnAgent, hasArtifact: false,
            latestReplyId: "reply_1", latestReplyState: .queued, latestReplyChoice: "seventy",
            latestReplyMessage: "an earlier note",
            createdAt: "2026-09-26T10:00:00Z", updatedAt: "2026-09-26T10:00:00Z"
        )
    }

    /// A review ask whose queued reply carries one comment on one capture
    /// (docs/stories/HAIL-34.md, operator decision via Knock on case
    /// c_656dc5ce…, choice "restore") - `beginChangingAnswer()`'s comment/
    /// capture-restore source. Returns the reply separately since `Case`
    /// itself only denormalizes the choice/message, not the comment list.
    private func answeredReviewCaseWithAComment() -> (Case, Reply) {
        let knockCase = Case(
            id: "c4", taskId: "t1", kind: .review, title: "Checkout layout",
            need: "Pick one", why: "Not a technical call",
            recommendation: "a", recommendationWhy: "It is faster",
            options: [Option(id: "a", label: "A · Compact"), Option(id: "b", label: "B · Detailed")],
            status: .waitingOnAgent, hasArtifact: true,
            latestReplyId: "reply_2", latestReplyState: .queued, latestReplyChoice: "a",
            createdAt: "2026-09-26T10:00:00Z", updatedAt: "2026-09-26T10:00:00Z"
        )
        let pngBase64 = solidImage().pngData()!.base64EncodedString()
        let reply = Reply(
            id: "reply_2", caseId: "c4", idempotencyKey: "k2", choice: "a",
            comments: [Comment(id: "cm_1", captureId: "cap_1", n: 1, rect: Rect(x: 0.1, y: 0.1, w: 0.2, h: 0.2), text: "Make this blue")],
            captures: [Capture(id: "cap_1", revision: 1, pngBase64: pngBase64, annotatedPngBase64: pngBase64, takenAt: "2026-09-26T09:59:00Z", note: nil)],
            state: .queued, createdAt: "2026-09-26T09:59:30Z"
        )
        return (knockCase, reply)
    }

    /// A review ask whose queued reply carries two comments on one capture -
    /// `changingAnswerAndSendingCarriesTheSurvivingRestoredComment`'s source,
    /// to prove removing one restored comment leaves the other intact all
    /// the way through to the `reply.replace` payload.
    private func answeredReviewCaseWithTwoComments() -> (Case, Reply) {
        let knockCase = Case(
            id: "c5", taskId: "t1", kind: .review, title: "Checkout layout",
            need: "Pick one", why: "Not a technical call",
            recommendation: "a", recommendationWhy: "It is faster",
            options: [Option(id: "a", label: "A · Compact"), Option(id: "b", label: "B · Detailed")],
            status: .waitingOnAgent, hasArtifact: true,
            latestReplyId: "reply_3", latestReplyState: .queued, latestReplyChoice: "a",
            createdAt: "2026-09-26T10:00:00Z", updatedAt: "2026-09-26T10:00:00Z"
        )
        let pngBase64 = solidImage().pngData()!.base64EncodedString()
        let reply = Reply(
            id: "reply_3", caseId: "c5", idempotencyKey: "k3", choice: "a",
            comments: [
                Comment(id: "cm_1", captureId: "cap_1", n: 1, rect: Rect(x: 0.1, y: 0.1, w: 0.2, h: 0.2), text: "Drop this one"),
                Comment(id: "cm_2", captureId: "cap_1", n: 2, rect: Rect(x: 0.3, y: 0.3, w: 0.2, h: 0.2), text: "Keep this one"),
            ],
            captures: [Capture(id: "cap_1", revision: 1, pngBase64: pngBase64, annotatedPngBase64: pngBase64, takenAt: "2026-09-26T09:59:00Z", note: nil)],
            state: .queued, createdAt: "2026-09-26T09:59:30Z"
        )
        return (knockCase, reply)
    }

    private func startEchoServer() async throws -> (server: FakeKnockServer, client: KnockClient, socketPath: String) {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard method == "reply.submit", let id,
                  let reply = try? JSONDecoder().decode(SubmitEnvelope.self, from: line).params
            else { return nil }
            return jsonRPCOK(
                id: id,
                result: #"{"id":"r_1","case_id":"\#(reply.caseId)","idempotency_key":"\#(reply.idempotencyKey)","choice":null,"message":null,"comments":[],"captures":[],"state":"queued","created_at":"2026-09-26T10:00:00Z"}"#
            )
        }
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        return (server, client, socketPath)
    }

    @Test func sendWithNoCommentsGoesStraightThroughWithoutTheReviewStep() async throws {
        let (server, client, _) = try await startEchoServer()
        defer { server.stop() }

        var sentCount = 0
        let store = CommentsSessionStore()
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        let flow = SendFlowController(knockCase: optionsCase(), commentsStore: store, coordinator: coordinator, onSent: { sentCount += 1 })

        flow.composer.selectOption("a")  // WAG-328: an empty Send sends nothing, so the person picks first
        flow.send()
        // `send()` kicks off an unstructured Task internally: await its effect.
        try await waitForSend { sentCount == 1 }

        #expect(flow.isReviewingBeforeSend == false)
        #expect(sentCount == 1)
        await client.stop()
    }

    /// 29 Sep (operator: "after sending, it should go back to the list
    /// view, and not asking me to send"): Send sends at once, comments
    /// included - no "You're sending" confirmation step in between.
    @Test func sendWithCommentsSendsImmediately() async throws {
        let (server, client, _) = try await startEchoServer()
        defer { server.stop() }

        let store = CommentsSessionStore()
        store.addCapture(image: NSImage(size: NSSize(width: 10, height: 10)), revision: 1)
        store.beginDraft(rect: Rect(x: 0.1, y: 0.1, w: 0.2, h: 0.1))
        store.updateDraftText("fix this")
        store.commitDraft()

        var sentCount = 0
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        let flow = SendFlowController(knockCase: optionsCase(), commentsStore: store, coordinator: coordinator, onSent: { sentCount += 1 })

        flow.send()
        try await waitForSend { sentCount == 1 }

        #expect(flow.isReviewingBeforeSend == false)
        #expect(sentCount == 1, "a commented reply goes out on the first Send")
        await client.stop()
    }

    @Test func keepEditingLeavesTheEvidenceReviewStepWithoutSending() async throws {
        let (server, client, _) = try await startEchoServer()
        defer { server.stop() }

        var sentCount = 0
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        let flow = SendFlowController(
            knockCase: optionsCase(), commentsStore: CommentsSessionStore(), coordinator: coordinator,
            onSent: { sentCount += 1 }, environment: ["KNOCK_REVIEW_STEP": "send"]
        )
        #expect(flow.isReviewingBeforeSend)

        flow.keepEditing()
        #expect(flow.isReviewingBeforeSend == false)
        #expect(sentCount == 0)
        await client.stop()
    }

    @Test func sendWithCommentsDeliversTheReplyAndCallsOnSent() async throws {
        let (server, client, _) = try await startEchoServer()
        defer { server.stop() }

        let store = CommentsSessionStore()
        store.addCapture(image: NSImage(size: NSSize(width: 10, height: 10)), revision: 1)
        store.beginDraft(rect: Rect(x: 0.1, y: 0.1, w: 0.2, h: 0.1))
        store.updateDraftText("fix this")
        store.commitDraft()

        var sentCount = 0
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        let flow = SendFlowController(knockCase: optionsCase(), commentsStore: store, coordinator: coordinator, onSent: { sentCount += 1 })

        flow.send()
        try await waitForSend { sentCount == 1 }

        #expect(flow.isReviewingBeforeSend == false)
        #expect(sentCount == 1)
        #expect(flow.errorMessage == nil)
        await client.stop()
    }

    /// Contract "Next ask": a decision reply sent from the case pane or the
    /// review window calls `onAnswerSent`, the hook `AppModel.
    /// advanceAfterSend` is wired to.
    @Test func sendWithNoCommentsCallsOnAnswerSent() async throws {
        let (server, client, _) = try await startEchoServer()
        defer { server.stop() }

        var answerSentCount = 0
        let store = CommentsSessionStore()
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        let flow = SendFlowController(
            knockCase: optionsCase(), commentsStore: store, coordinator: coordinator,
            onSent: {}, onAnswerSent: { _ in answerSentCount += 1 }
        )

        flow.composer.selectOption("a")  // WAG-328: an empty Send sends nothing, so the person picks first
        flow.send()
        try await waitForSend { answerSentCount == 1 }

        #expect(answerSentCount == 1)
        await client.stop()
    }

    @Test func acceptRecommendationUsesTheRecommendationRegardlessOfTheDraftText() async throws {
        let (server, client, _) = try await startEchoServer()
        defer { server.stop() }

        let store = CommentsSessionStore()
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        var sentCount = 0
        let flow = SendFlowController(knockCase: optionsCase(), commentsStore: store, coordinator: coordinator, onSent: { sentCount += 1 })
        flow.composer.selectOption("b")
        flow.composer.draftText = "would have overridden the choice"

        flow.acceptRecommendation()
        try await waitForSend { sentCount == 1 }

        #expect(sentCount == 1)
        #expect(flow.pendingReplyValue == "A · Compact", "accepting the recommendation ignores the manually selected option and any typed text")
        await client.stop()
    }

    /// docs/stories/HAIL-25.md: "The pane shows the composer footer from
    /// M7 ... Sending uses the existing send pipeline" - a question ask's
    /// own selection (not the recommendation) must reach `reply.submit`
    /// through `SendCoordinator`, exactly as the review workspace's Send
    /// already does.
    @Test func aQuestionAskSendGoesThroughSendCoordinatorWithTheSelectedChoice() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let capturedChoice = LockedBox()
        server.onRequest = { method, id, line in
            guard method == "reply.submit", let id,
                  let reply = try? JSONDecoder().decode(SubmitEnvelope.self, from: line).params
            else { return nil }
            capturedChoice.set(reply.choice)
            return jsonRPCOK(
                id: id,
                result: #"{"id":"r_1","case_id":"\#(reply.caseId)","idempotency_key":"\#(reply.idempotencyKey)","choice":null,"message":null,"comments":[],"captures":[],"state":"queued","created_at":"2026-09-26T10:00:00Z"}"#
            )
        }
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        defer { server.stop() }

        let store = CommentsSessionStore()
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        var sentCount = 0
        let flow = SendFlowController(
            knockCase: questionCase(), commentsStore: store, coordinator: coordinator,
            draftStore: ComposerDraftStore(), onSent: { sentCount += 1 }
        )

        flow.composer.selectOption("sixty")
        flow.send()
        try await waitForSend { sentCount == 1 && capturedChoice.value != nil }

        #expect(sentCount == 1)
        #expect(capturedChoice.value == "sixty", "the pane's own selection, not the recommendation, should reach reply.submit")
        await client.stop()
    }

    /// App check 2026-11-09 (the evidence hook sent 2 and 4 replies): a real Send, pressed again in the same turn (a
    /// double click, ↵ right after the button), delivers one reply. The second call is a no-op.
    @Test func twoSendsInTheSameTurnDeliverOneReply() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let submits = SubmitCounter()
        server.onRequest = { method, id, line in
            guard method == "reply.submit", let id,
                  let reply = try? JSONDecoder().decode(SubmitEnvelope.self, from: line).params
            else { return nil }
            submits.bump()
            return jsonRPCOK(
                id: id,
                result: #"{"id":"r_1","case_id":"\#(reply.caseId)","idempotency_key":"\#(reply.idempotencyKey)","choice":null,"message":null,"comments":[],"captures":[],"state":"queued","created_at":"2026-09-26T10:00:00Z"}"#
            )
        }
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        defer { server.stop() }

        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        var sentCount = 0
        let flow = SendFlowController(
            knockCase: questionCase(), commentsStore: CommentsSessionStore(), coordinator: coordinator,
            draftStore: ComposerDraftStore(), onSent: { sentCount += 1 })

        flow.composer.selectOption("sixty")
        flow.send()
        flow.send()
        flow.acceptRecommendation()
        try await waitForSend { sentCount >= 1 }
        // Give a second delivery, if one had started, the time to reach the server.
        try await Task.sleep(for: .milliseconds(300))

        #expect(sentCount == 1)
        #expect(submits.value == 1)
        await client.stop()
    }

    /// WAG-285: feedback on a multi-question page goes out as a plain message: no choice, no choices, no answers.
    @Test func feedbackWithNoAnswerGoesOutAsAMessageOnly() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let captured = LockedBox()
        server.onRequest = { method, id, line in
            guard method == "reply.submit", let id,
                  let reply = try? JSONDecoder().decode(SubmitEnvelope.self, from: line).params
            else { return nil }
            let shape = "choice=\(reply.choice ?? "nil") choices=\(reply.choices?.description ?? "nil") answers=\(reply.answers?.count.description ?? "nil") message=\(reply.message ?? "nil") intent=\(reply.intent.rawValue)"
            captured.set(shape)
            return jsonRPCOK(
                id: id,
                result: #"{"id":"r_1","case_id":"\#(reply.caseId)","idempotency_key":"\#(reply.idempotencyKey)","choice":null,"message":null,"comments":[],"captures":[],"state":"queued","created_at":"2026-09-26T10:00:00Z"}"#
            )
        }
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        defer { server.stop() }

        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        var sentCount = 0
        let flow = SendFlowController(
            knockCase: questionCase(), commentsStore: CommentsSessionStore(), coordinator: coordinator,
            draftStore: ComposerDraftStore(), onSent: { sentCount += 1 })

        flow.sendFeedback(message: nil)
        flow.sendFeedback(message: "Make the prototype navigable.")
        try await waitForSend { sentCount == 1 }

        #expect(sentCount == 1)
        #expect(captured.value == "choice=nil choices=nil answers=nil message=Make the prototype navigable. intent=decision")
        await client.stop()
    }

    /// HAIL-41: a review ask answered right in the case pane goes through
    /// the exact same `SendFlowController` → `SendCoordinator` → `reply.
    /// submit` pipeline a question ask uses - the pane never carries
    /// comments (`CommentsSessionStore()` stays empty, same as the case
    /// pane's own real `sendFlow`), so this reaches `confirmSend` directly,
    /// with no review-before-send step in between.
    @Test func aReviewAskPaneSendGoesThroughSendCoordinatorWithTheSelectedChoiceAndMessage() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let captured = LockedBox()
        server.onRequest = { method, id, line in
            guard method == "reply.submit", let id,
                  let reply = try? JSONDecoder().decode(SubmitEnvelope.self, from: line).params
            else { return nil }
            captured.set("\(reply.choice ?? "nil")|\(reply.message ?? "nil")")
            return jsonRPCOK(
                id: id,
                result: #"{"id":"r_1","case_id":"\#(reply.caseId)","idempotency_key":"\#(reply.idempotencyKey)","choice":null,"message":null,"comments":[],"captures":[],"state":"queued","created_at":"2026-09-26T10:00:00Z"}"#
            )
        }
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        defer { server.stop() }

        let store = CommentsSessionStore()
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        var sentCount = 0
        let flow = SendFlowController(
            knockCase: optionsCase(), commentsStore: store, coordinator: coordinator,
            draftStore: ComposerDraftStore(), onSent: { sentCount += 1 }
        )

        flow.composer.selectOption("b")
        flow.composer.draftText = "go with B, it reads clearer"
        flow.send()
        try await waitForSend { sentCount == 1 }

        #expect(flow.isReviewingBeforeSend == false, "no comments pinned, so this sends straight through, same as a question ask")
        #expect(sentCount == 1)
        #expect(captured.value == "b|go with B, it reads clearer")
        await client.stop()
    }

    /// docs/stories/HAIL-36.md: "Typing a reply and sending with no option
    /// selected sends choice: nil and the message" - the reply that reaches
    /// `reply.submit` must not silently carry the recommendation just
    /// because nothing else was picked.
    @Test func sendingWithATypedMessageAndNoSelectionSendsANilChoice() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let captured = LockedBox()
        server.onRequest = { method, id, line in
            guard method == "reply.submit", let id,
                  let reply = try? JSONDecoder().decode(SubmitEnvelope.self, from: line).params
            else { return nil }
            captured.set("\(reply.choice ?? "nil")|\(reply.message ?? "nil")")
            return jsonRPCOK(
                id: id,
                result: #"{"id":"r_1","case_id":"\#(reply.caseId)","idempotency_key":"\#(reply.idempotencyKey)","choice":null,"message":null,"comments":[],"captures":[],"state":"queued","created_at":"2026-09-26T10:00:00Z"}"#
            )
        }
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        defer { server.stop() }

        let store = CommentsSessionStore()
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        let flow = SendFlowController(knockCase: questionCase(), commentsStore: store, coordinator: coordinator, onSent: {})

        flow.composer.draftText = "actually, let's go with 65/25/10"
        flow.send()
        try await waitForSend { captured.value != nil }

        #expect(captured.value == "nil|actually, let's go with 65/25/10")
        await client.stop()
    }

    /// docs/stories/HAIL-43.md AC: "send with a cleared option sends choice
    /// nil + message" - clicking the selected option again before sending
    /// must not leave the choice it just backed out of on the wire.
    @Test func sendingAfterDeselectingTheChosenOptionSendsANilChoice() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let captured = LockedBox()
        server.onRequest = { method, id, line in
            guard method == "reply.submit", let id,
                  let reply = try? JSONDecoder().decode(SubmitEnvelope.self, from: line).params
            else { return nil }
            captured.set("\(reply.choice ?? "nil")|\(reply.message ?? "nil")")
            return jsonRPCOK(
                id: id,
                result: #"{"id":"r_1","case_id":"\#(reply.caseId)","idempotency_key":"\#(reply.idempotencyKey)","choice":null,"message":null,"comments":[],"captures":[],"state":"queued","created_at":"2026-09-26T10:00:00Z"}"#
            )
        }
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        defer { server.stop() }

        let store = CommentsSessionStore()
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        let flow = SendFlowController(
            knockCase: optionsCase(), commentsStore: store, coordinator: coordinator,
            draftStore: ComposerDraftStore(), onSent: {}
        )

        flow.composer.selectOption("b")
        flow.composer.selectOption("b")
        flow.composer.draftText = "just a comment, no pick"
        flow.send()
        try await waitForSend { captured.value != nil }

        #expect(captured.value == "nil|just a comment, no pick")
        await client.stop()
    }

    /// docs/stories/HAIL-36.md: "Accept recommendation still sends the
    /// recommendation explicitly" - unaffected by the composer's new default
    /// of no selection, since this action never reads `selectedOptionId`.
    @Test func acceptRecommendationSendsItEvenWithTheDefaultNoSelection() async throws {
        let (server, client, _) = try await startEchoServer()
        defer { server.stop() }

        let store = CommentsSessionStore()
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        var sentCount = 0
        let flow = SendFlowController(
            knockCase: optionsCase(), commentsStore: store, coordinator: coordinator,
            // A fresh store, not `.shared` (the default): another test in
            // this suite persists a selection for this same case id into the
            // shared store, which would otherwise leak into this one.
            draftStore: ComposerDraftStore(), onSent: { sentCount += 1 }
        )

        #expect(flow.composer.selectedOptionId == nil, "the default, before this test touches anything")
        flow.acceptRecommendation()
        try await waitForSend { sentCount == 1 }

        #expect(sentCount == 1)
        #expect(flow.pendingReplyValue == "A · Compact")
        await client.stop()
    }

    /// docs/stories/HAIL-25.md: "the pane and the review share one draft per
    /// case" - the review workspace builds its own `SendFlowController`
    /// (`ReviewWorkspaceView`, left untouched by this story), so the sharing
    /// must work through `draftStore` alone, with no object in common.
    @Test func aSelectionMadeOnOneControllerIsVisibleOnAnotherThatSharesItsDraftStore() async throws {
        let (server, client, _) = try await startEchoServer()
        defer { server.stop() }

        let sharedStore = ComposerDraftStore()
        let paneCoordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        let paneFlow = SendFlowController(
            knockCase: optionsCase(), commentsStore: CommentsSessionStore(), coordinator: paneCoordinator,
            draftStore: sharedStore, onSent: {}
        )
        paneFlow.composer.selectOption("b")
        paneFlow.composer.draftText = "keep this above the fold"

        let reviewCoordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        let reviewFlow = SendFlowController(
            knockCase: optionsCase(), commentsStore: CommentsSessionStore(), coordinator: reviewCoordinator,
            draftStore: sharedStore, onSent: {}
        )

        #expect(reviewFlow.composer.selectedOptionId == "b")
        #expect(reviewFlow.composer.draftText == "keep this above the fold")
        await client.stop()
    }

    // MARK: - New round opens empty (HAIL-74)

    @Test func afterASendTheNextComposerForTheCaseOpensEmpty() async throws {
        let (server, client, _) = try await startEchoServer()
        defer { server.stop() }

        let store = ComposerDraftStore()
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        let flow = SendFlowController(
            knockCase: optionsCase(), commentsStore: CommentsSessionStore(), coordinator: coordinator,
            draftStore: store, onSent: {}
        )
        flow.composer.selectOption("b")
        flow.composer.draftText = "Put them in an html prototype"
        flow.send()
        try await waitForSend { flow.composer.draftText == "" }

        #expect(flow.composer.draftText == "")
        #expect(flow.composer.selectedOptionId == nil)
        // A composer built later (the review workspace, or the pane again) restores nothing.
        let next = ComposerViewModel(knockCase: optionsCase(), draftStore: store)
        #expect(next.draftText == "")
        #expect(next.selectedOptionId == nil)
        await client.stop()
    }

    @Test func startNewRoundEmptiesTheComposerAndTheCommentCount() async throws {
        let (server, client, _) = try await startEchoServer()
        defer { server.stop() }

        let store = ComposerDraftStore()
        let commentsStore = CommentsSessionStore()
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        let flow = SendFlowController(
            knockCase: optionsCase(), commentsStore: commentsStore, coordinator: coordinator,
            draftStore: store, onSent: {}
        )
        flow.composer.selectOption("a")
        flow.composer.draftText = "old reply"
        let capture = commentsStore.addCapture(image: NSImage(size: NSSize(width: 4, height: 4)), revision: 1)
        commentsStore.beginDraft(rect: Rect(x: 0, y: 0, w: 0.1, h: 0.1), on: capture.id)
        commentsStore.updateDraftText("old comment")
        commentsStore.commitDraft()
        #expect(commentsStore.model.comments.count == 1)

        flow.startNewRound()

        #expect(flow.composer.draftText == "")
        #expect(flow.composer.selectedOptionId == nil)
        #expect(commentsStore.model.comments.isEmpty)
        #expect(ComposerViewModel(knockCase: optionsCase(), draftStore: store).draftText == "")
        await client.stop()
    }

    @Test func cancellingChangeAnswerLeavesNoDraftBehind() async throws {
        let (server, client, _) = try await startEchoServer()
        defer { server.stop() }

        let store = ComposerDraftStore()
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        let knockCase = answeredQuestionCase()
        let flow = SendFlowController(
            knockCase: knockCase, commentsStore: CommentsSessionStore(), coordinator: coordinator,
            client: client, draftStore: store, onSent: {}
        )
        flow.beginChangingAnswer()
        #expect(flow.composer.draftText == "an earlier note")

        flow.cancelChangingAnswer()

        #expect(!flow.isEditingLockedAnswer)
        #expect(flow.composer.draftText == "")
        #expect(ComposerViewModel(knockCase: knockCase, draftStore: store).draftText == "")
        await client.stop()
    }

    // MARK: - "Change answer" (HAIL-34)

    @Test func beginChangingAnswerPrefillsFromTheExistingReplyRatherThanTheSharedDraft() async throws {
        let (server, client, _) = try await startEchoServer()
        defer { server.stop() }

        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        let flow = SendFlowController(
            knockCase: answeredQuestionCase(), commentsStore: CommentsSessionStore(), coordinator: coordinator,
            client: client, draftStore: ComposerDraftStore(), onSent: {}
        )
        // A stale draft from some earlier, unrelated selection - `beginChangingAnswer`
        // must overwrite it with what was actually sent, not leave it in place.
        flow.composer.selectOption("sixty")
        flow.composer.draftText = "a stray draft from before"

        flow.beginChangingAnswer()

        #expect(flow.isEditingLockedAnswer)
        #expect(flow.composer.selectedOptionId == "seventy")
        #expect(flow.composer.draftText == "an earlier note")
        await client.stop()
    }

    /// Operator decision via Knock (case c_656dc5ce…, choice "restore"):
    /// "Change answer" reopens the composer with the earlier round's
    /// comments and annotated captures restored from `CaseDetail.replies`,
    /// not a blank Comment-mode session.
    @Test func beginChangingAnswerRestoresTheExistingReplysCommentsAndCaptures() async throws {
        let (server, client, _) = try await startEchoServer()
        defer { server.stop() }

        let (knockCase, reply) = answeredReviewCaseWithAComment()
        let commentsStore = CommentsSessionStore()
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        let flow = SendFlowController(
            knockCase: knockCase, commentsStore: commentsStore, coordinator: coordinator,
            client: client, replies: [reply], draftStore: ComposerDraftStore(), onSent: {}
        )

        flow.beginChangingAnswer()

        #expect(commentsStore.model.captures.map(\.id) == ["cap_1"])
        #expect(commentsStore.imagesByCaptureId["cap_1"] != nil)
        #expect(commentsStore.model.comments(on: "cap_1").map(\.text) == ["Make this blue"])
        await client.stop()
    }

    /// Removing a restored comment before sending drops only that one - the
    /// rest of the restored session (and the reply.replace it produces) is
    /// unaffected.
    @Test func removingARestoredCommentBeforeSendingDropsOnlyThatOne() async throws {
        let (server, client, _) = try await startEchoServer()
        defer { server.stop() }

        let (knockCase, reply) = answeredReviewCaseWithAComment()
        let commentsStore = CommentsSessionStore()
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        let flow = SendFlowController(
            knockCase: knockCase, commentsStore: commentsStore, coordinator: coordinator,
            client: client, replies: [reply], draftStore: ComposerDraftStore(), onSent: {}
        )

        flow.beginChangingAnswer()
        let commentId = commentsStore.model.comments(on: "cap_1").first!.id
        commentsStore.deleteComment(id: commentId)

        #expect(commentsStore.model.comments(on: "cap_1").isEmpty)
        // HAIL-65: a capture left without comments is never kept.
        #expect(commentsStore.model.captures.isEmpty)
        await client.stop()
    }

    /// "reply.replace carries the rest" (docs/stories/HAIL-34.md fold): after
    /// restoring two comments and removing one, sending the changed answer's
    /// `reply.replace` payload carries only the one still there.
    @Test func changingAnswerAndSendingCarriesTheSurvivingRestoredComment() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let capturedTexts = LockedBox()
        server.onRequest = { method, id, line in
            guard method == "reply.replace", let id else { return nil }
            if let envelope = try? JSONDecoder().decode(ReplaceCommentsEnvelope.self, from: line) {
                capturedTexts.set(envelope.params.comments.map(\.text).joined(separator: "|"))
            }
            return jsonRPCOK(
                id: id,
                result: #"{"id":"reply_3","case_id":"c5","idempotency_key":"k3","choice":"a","message":null,"comments":[],"captures":[],"state":"queued","created_at":"2026-09-26T09:59:30Z","replaced_at":"2026-09-26T10:05:00Z"}"#
            )
        }
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        defer { server.stop() }

        let (knockCase, reply) = answeredReviewCaseWithTwoComments()
        let commentsStore = CommentsSessionStore()
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        let flow = SendFlowController(
            knockCase: knockCase, commentsStore: commentsStore, coordinator: coordinator,
            client: client, replies: [reply], draftStore: ComposerDraftStore(), onSent: {}
        )

        flow.beginChangingAnswer()
        let dropId = commentsStore.model.comments(on: "cap_1").first { $0.text == "Drop this one" }!.id
        commentsStore.deleteComment(id: dropId)

        flow.send()
        try await waitForSend { capturedTexts.value != nil }

        #expect(capturedTexts.value == "Keep this one")
        await client.stop()
    }

    /// Contract "Next ask": "Change answer" on an already-queued reply never
    /// calls `onAnswerSent` - it goes through `confirmReplace`, not the
    /// `confirmSend` branch `onAnswerSent` is wired to. (`AppModel.
    /// advanceAfterSend` would also no-op for this case on its own, since
    /// it already left `needsYouCases` - this proves the controller itself
    /// never even offers it the chance.)
    @Test func changingAnAnswerNeverCallsOnAnswerSent() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard method == "reply.replace", let id else { return nil }
            return jsonRPCOK(
                id: id,
                result: #"{"id":"reply_1","case_id":"c3","idempotency_key":"k1","choice":"sixty","message":null,"comments":[],"captures":[],"state":"queued","created_at":"2026-09-26T10:00:00Z","replaced_at":"2026-09-26T10:05:00Z"}"#
            )
        }
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        defer { server.stop() }

        var answerSentCount = 0
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        let flow = SendFlowController(
            knockCase: answeredQuestionCase(), commentsStore: CommentsSessionStore(), coordinator: coordinator,
            client: client, draftStore: ComposerDraftStore(), onSent: {}, onAnswerSent: { _ in answerSentCount += 1 }
        )

        flow.beginChangingAnswer()
        flow.composer.selectOption("sixty")
        flow.send()
        try await waitForSend { !flow.isEditingLockedAnswer }

        #expect(answerSentCount == 0)
        await client.stop()
    }

    @Test func sendWhileEditingALockedAnswerCallsReplyReplaceRatherThanReplySubmit() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let capturedMethod = LockedBox()
        server.onRequest = { method, id, line in
            capturedMethod.set(method)
            guard method == "reply.replace", let id else { return nil }
            return jsonRPCOK(
                id: id,
                result: #"{"id":"reply_1","case_id":"c3","idempotency_key":"k1","choice":"sixty","message":null,"comments":[],"captures":[],"state":"queued","created_at":"2026-09-26T10:00:00Z","replaced_at":"2026-09-26T10:05:00Z"}"#
            )
        }
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        defer { server.stop() }

        var sentCount = 0
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        let flow = SendFlowController(
            knockCase: answeredQuestionCase(), commentsStore: CommentsSessionStore(), coordinator: coordinator,
            client: client, draftStore: ComposerDraftStore(), onSent: { sentCount += 1 }
        )

        flow.beginChangingAnswer()
        flow.composer.selectOption("sixty")
        flow.send()
        try await waitForSend { capturedMethod.value != nil && !flow.isEditingLockedAnswer }

        #expect(capturedMethod.value == "reply.replace")
        #expect(flow.isEditingLockedAnswer == false, "a successful replace returns to the locked, queued display")
        #expect(sentCount == 1)
        await client.stop()
    }

    // MARK: - Ask for more detail (HAIL-33)

    /// "Ask" ⌘↵ submits a `more_detail` reply with no choice and the typed
    /// question as the message, straight through - no review-before-send
    /// step (docs/stories/HAIL-33.md).
    @Test func askForMoreDetailSubmitsAMoreDetailReplyWithNoChoice() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let captured = LockedBox()
        server.onRequest = { method, id, line in
            guard method == "reply.submit", let id,
                  let reply = try? JSONDecoder().decode(SubmitEnvelope.self, from: line).params
            else { return nil }
            captured.set("\(reply.intent.rawValue)|\(reply.choice ?? "nil")|\(reply.message ?? "nil")")
            return jsonRPCOK(
                id: id,
                result: #"{"id":"r_1","case_id":"\#(reply.caseId)","idempotency_key":"\#(reply.idempotencyKey)","choice":null,"message":"\#(reply.message ?? "")","intent":"more_detail","comments":[],"captures":[],"state":"queued","created_at":"2026-09-26T10:00:00Z"}"#
            )
        }
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        defer { server.stop() }

        var sentCount = 0
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        let flow = SendFlowController(knockCase: questionCase(), commentsStore: CommentsSessionStore(), coordinator: coordinator, onSent: { sentCount += 1 })

        flow.composer.beginAskingForDetail()
        flow.composer.fillDetailChip("Show me the numbers")
        flow.askForMoreDetail()
        try await waitForSend { captured.value != nil && flow.deliveryReplySummary != nil }

        #expect(captured.value == "more_detail|nil|Show me the numbers")
        #expect(flow.deliveryReplySummary == "Asked for more detail · Show me the numbers")
        #expect(sentCount == 1)
        #expect(flow.composer.isAskingForDetail == false, "a successful ask closes the inline field again")
        await client.stop()
    }

    /// The question is optional (docs/stories/HAIL-33.md: "What would help?
    /// (optional)") - an empty field still submits, with a nil message.
    @Test func askForMoreDetailWithNoQuestionSubmitsANilMessage() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let captured = LockedBox()
        server.onRequest = { method, id, line in
            guard method == "reply.submit", let id,
                  let reply = try? JSONDecoder().decode(SubmitEnvelope.self, from: line).params
            else { return nil }
            captured.set(reply.message ?? "nil")
            return jsonRPCOK(
                id: id,
                result: #"{"id":"r_1","case_id":"\#(reply.caseId)","idempotency_key":"\#(reply.idempotencyKey)","choice":null,"message":null,"intent":"more_detail","comments":[],"captures":[],"state":"queued","created_at":"2026-09-26T10:00:00Z"}"#
            )
        }
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        defer { server.stop() }

        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        let flow = SendFlowController(knockCase: questionCase(), commentsStore: CommentsSessionStore(), coordinator: coordinator, onSent: {})

        flow.composer.beginAskingForDetail()
        flow.askForMoreDetail()
        try await waitForSend { captured.value != nil }

        #expect(captured.value == "nil")
        await client.stop()
    }

    /// HAIL-139: the one-tap format rows send a `more_detail` reply with the
    /// format and no question, straight through the same send path.
    @Test func askForMoreDetailWithAFormatSubmitsTheFormatWithNoMessage() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let captured = LockedBox()
        server.onRequest = { method, id, line in
            guard method == "reply.submit", let id,
                  let reply = try? JSONDecoder().decode(SubmitEnvelope.self, from: line).params
            else { return nil }
            captured.set("\(reply.intent.rawValue)|\(reply.format?.rawValue ?? "nil")|\(reply.message ?? "nil")")
            return jsonRPCOK(
                id: id,
                result: #"{"id":"r_1","case_id":"\#(reply.caseId)","idempotency_key":"\#(reply.idempotencyKey)","choice":null,"message":null,"intent":"more_detail","format":"diagram","comments":[],"captures":[],"state":"queued","created_at":"2026-09-26T10:00:00Z"}"#
            )
        }
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        defer { server.stop() }

        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        let flow = SendFlowController(knockCase: questionCase(), commentsStore: CommentsSessionStore(), coordinator: coordinator, onSent: {})

        flow.composer.beginAskingForDetail()
        flow.askForMoreDetail(format: .diagram)
        try await waitForSend { captured.value != nil && flow.deliveryReplySummary != nil }

        #expect(captured.value == "more_detail|diagram|nil")
        #expect(flow.deliveryReplySummary == "Asked for more detail · as a diagram")
        await client.stop()
    }

    /// Contract "Next ask": "Not after 'Ask for more detail' (stay on the
    /// same ask)" - `askForMoreDetail`'s success calls `onSent` (so the
    /// review window's own close-back-to-list behavior is unaffected) but
    /// never `onAnswerSent`, the hook `AppModel.advanceAfterSend` is wired
    /// to.
    @Test func askForMoreDetailNeverCallsOnAnswerSent() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard method == "reply.submit", let id,
                  let reply = try? JSONDecoder().decode(SubmitEnvelope.self, from: line).params
            else { return nil }
            return jsonRPCOK(
                id: id,
                result: #"{"id":"r_1","case_id":"\#(reply.caseId)","idempotency_key":"\#(reply.idempotencyKey)","choice":null,"message":"\#(reply.message ?? "")","intent":"more_detail","comments":[],"captures":[],"state":"queued","created_at":"2026-09-26T10:00:00Z"}"#
            )
        }
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        defer { server.stop() }

        var sentCount = 0
        var answerSentCount = 0
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        let flow = SendFlowController(
            knockCase: questionCase(), commentsStore: CommentsSessionStore(), coordinator: coordinator,
            onSent: { sentCount += 1 }, onAnswerSent: { _ in answerSentCount += 1 }
        )

        flow.composer.beginAskingForDetail()
        flow.composer.fillDetailChip("Show me the numbers")
        flow.askForMoreDetail()
        try await waitForSend { sentCount == 1 }

        #expect(sentCount == 1)
        #expect(answerSentCount == 0)
        await client.stop()
    }

    @Test func sendWhileEditingALockedAnswerSurfacesADaemonRejectionAndStaysInEditMode() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard method == "reply.replace", let id else { return nil }
            return Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32010,"message":"reply already delivered"}}"#.utf8)
        }
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        defer { server.stop() }

        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        let flow = SendFlowController(
            knockCase: answeredQuestionCase(), commentsStore: CommentsSessionStore(), coordinator: coordinator,
            client: client, draftStore: ComposerDraftStore(), onSent: {}
        )

        flow.beginChangingAnswer()
        flow.send()
        try await waitForSend { flow.errorMessage != nil }

        #expect(flow.isEditingLockedAnswer, "a rejection leaves the composer open rather than snapping back to the locked recap")
        #expect(flow.errorMessage != nil)
        #expect(flow.deliveryState.state == .idle, "never stuck on .sending after the daemon rejects the replace")
        await client.stop()
    }
}

/// A single thread-safe slot: `FakeKnockServer.onRequest` runs on its own
/// background accept thread, so a plain `var` capture would race.
private final class LockedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    func set(_ value: String?) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class SubmitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func bump() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
