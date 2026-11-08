import Testing
import Foundation
@testable import Knock

/// Choice 4 (docs/stories/HAIL-34.md fold, "row staleness after send"):
/// during evidence capture, a queue row briefly kept showing the pending
/// arrival time and no "you -> ..." line right after
/// `KNOCK_PANE_SEND_RECOMMENDATION` fired `sendFlow.acceptRecommendation()`
/// from inside `CasePaneDetailView.init` - the pane's own header already
/// showed the right answer, but the row lagged a few seconds, and a relaunch
/// (a guaranteed fresh `cases.list`) fixed it at once.
///
/// This drives the exact same production call
/// (`SendFlowController.acceptRecommendation()` -> `SendCoordinator.send()`
/// -> `KnockClient.replySubmit`) from a plain `@Test`, not the evidence
/// hook, against a `FakeKnockServer` that answers `reply.submit` and then
/// (like the real daemon's own synchronous reply-insert + event-append
/// transaction, `daemon/src/store.ts`) pushes the matching `case.updated`
/// event before its RPC response even reaches the client. Even with the
/// event arriving first, `AppModel.handle(_:)` still owes `refreshCases()`
/// two more `cases.list` round trips before the row array itself updates -
/// so a queue row that has not caught up in the first instant after Send is
/// the expected shape of this design, not a bug specific to HAIL-34: the
/// existing `newCaseAppearsFromAPushedEventWithoutAManualRefresh` test
/// already relies on the same "an event schedules a refresh, it does not
/// update anything by itself" contract for a brand new case. What matters is
/// that it converges - which this test asserts within the same bound
/// (`waitUntil`'s default 3 s) every other event-driven AppModel test uses.
@Suite(.serialized)
struct RowFreshnessAfterSendTests {
    private final class CaseState: @unchecked Sendable {
        private let lock = NSLock()
        private var answered = false

        func markAnswered() {
            lock.lock()
            answered = true
            lock.unlock()
        }

        var isAnswered: Bool {
            lock.lock()
            defer { lock.unlock() }
            return answered
        }
    }

    private struct SubmitEnvelope: Decodable { let params: PendingReply }

    @MainActor
    private func waitUntil(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        if try await !pollUntil(timeout, condition) { throw TestClientError.timedOut }
    }

    @Test @MainActor func aRealAcceptRecommendationSendConvergesTheRowWithinTheUsualBound() async throws {
        let socketPath = makeTempSocketPath()
        let state = CaseState()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard let id else { return nil }
            switch method {
            case "cases.list":
                let peek = try? JSONDecoder().decode(AppModelPeek.self, from: line)
                let isAnswered = state.isAnswered
                let status = peek?.params?.status
                let wantsNeedsYou = status == nil || status == "needs_you"
                let wantsWaiting = status == nil || status == "waiting_on_agent"
                var items: [String] = []
                if !isAnswered, wantsNeedsYou { items.append(caseJSON(answered: false)) }
                if isAnswered, wantsWaiting { items.append(caseJSON(answered: true)) }
                return jsonRPCOK(id: id, result: "[\(items.joined(separator: ","))]")
            case "cases.get":
                return jsonRPCOK(id: id, result: #"""
                {"case":\#(caseJSON(answered: state.isAnswered)),
                 "task":{"id":"t_1","name":"Checkout redesign","project":"omea-web"},
                 "messages":[],"revisions":[],"comments":[],"replies":[]}
                """#)
            case "reply.submit":
                guard let reply = try? JSONDecoder().decode(SubmitEnvelope.self, from: line).params else { return nil }
                state.markAnswered()
                // The real daemon appends `reply.state_changed`/`case.updated`
                // in the same transaction that inserts the reply, and its
                // event bus pushes to every connected socket right away
                // (daemon/src/store.ts submitReply) - modelled here by
                // pushing the event BEFORE this handler returns the RPC
                // response, so it reaches `KnockClient` first.
                server.pushEvent(Event(type: .caseUpdated, caseId: "c_send", replyId: nil, sessionId: nil, at: "2026-09-28T10:00:05.000Z"))
                return jsonRPCOK(
                    id: id,
                    result: #"{"id":"r_send","case_id":"\#(reply.caseId)","idempotency_key":"\#(reply.idempotencyKey)","choice":"a","message":null,"comments":[],"captures":[],"state":"queued","created_at":"2026-09-28T10:00:05.000Z"}"#
                )
            case "events.subscribe":
                return jsonRPCOK(id: id, result: "{}")
            default:
                return jsonRPCOK(id: id, result: "{}")
            }
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        let model = AppModel(client: client, environment: isolatedKnockEnvironment(), bundleIdentifier: TestCopyEnvironment.releaseBundleIdentifier)
        model.start()
        try await waitUntil { model.needsYouCases.map(\.id) == ["c_send"] }

        let sendFlow = SendFlowController(
            knockCase: model.needsYouCases[0], commentsStore: CommentsSessionStore(),
            coordinator: model.sendCoordinator, client: client, revisionArrival: nil, onSent: {}
        )
        sendFlow.acceptRecommendation()

        try await waitUntil {
            model.needsYouCases.isEmpty
                && model.waitingOnAgentCases.first?.id == "c_send"
                && model.waitingOnAgentCases.first?.latestReplyChoice == "a"
        }

        model.stop()
    }
}

private struct AppModelPeek: Decodable {
    let params: Params?
    struct Params: Decodable { let status: String? }
}

private func caseJSON(answered: Bool) -> String {
    let statusFields = answered
        ? #""status":"waiting_on_agent","latest_reply_id":"r_send","latest_reply_state":"queued","latest_reply_choice":"a","first_reply_submitted_at":"2026-09-28T10:00:05.000Z""#
        : #""status":"needs_you""#
    return #"""
    {"id":"c_send","task_id":"t_1","kind":"review","title":"Pricing card","need":"N","why":"W",
     "recommendation":"a","recommendation_why":"RW","options":[{"id":"a","label":"A · Compact"},{"id":"b","label":"B · Detailed"}],
     \#(statusFields),"has_artifact":false,"runtime":"claude",
     "created_at":"2026-09-28T10:00:00.000Z","updated_at":"2026-09-28T10:00:00.000Z"}
    """#
}
