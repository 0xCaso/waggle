import Testing
import Foundation
@testable import Knock

private struct SubmitEnvelope: Decodable { let params: PendingReply }

private func replyResultJSON(id: String, replyId: String, idempotencyKey: String, state: String) -> String {
    #"""
    {"id":"\#(id)","case_id":"c1","idempotency_key":"\#(idempotencyKey)",
     "choice":null,"message":"go with A","comments":[],"captures":[],
     "state":"\#(state)","created_at":"2026-09-26T10:44:00Z"}
    """#
}

private let answeredCaseJSON = #"""
{"id":"c1","task_id":"t_1","kind":"review","title":"Pricing card","need":"N","why":"W",
 "recommendation":"a","recommendation_why":"RW","options":[{"id":"a","label":"A"}],
 "status":"waiting_on_agent","latest_reply_id":"reply_1","latest_reply_state":"delivered",
 "has_artifact":false,"runtime":"claude",
 "created_at":"2026-10-04T10:00:00.000Z","updated_at":"2026-10-04T10:00:00.000Z"}
"""#

/// `DeliveryStateViewModel`: the M8 delivery banner's state machine
/// (docs/design/mvp-values.md §M8 `Egyj0`) - every one of its four states,
/// reached the same way the real app reaches them (a fake daemon's
/// `reply.submit`/`reply.retry` responses), plus AC 8 ("A failed or unsent
/// reply never shows the delivered style"): each assertion below pins the
/// exact enum case, which by construction rules out the other three.
///
/// `.serialized`: same reason as `SendCoordinatorTests`/
/// `SendFlowControllerTests` - each test owns a real socket and background
/// accept thread.
@Suite(.serialized)
@MainActor
struct DeliveryStateViewModelTests {
    private func tempHome() -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("knock_delivery_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func reply(key: String = "key-1") -> PendingReply {
        PendingReply(caseId: "c1", idempotencyKey: key, choice: nil, message: "go with A", comments: [], captures: [])
    }

    private func makeCoordinator(client: KnockClient) -> SendCoordinator {
        SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
    }

    @Test func startsIdle() {
        let client = KnockClient(socketPath: makeTempSocketPath())
        let vm = DeliveryStateViewModel(coordinator: makeCoordinator(client: client), client: client)
        #expect(vm.state == .idle)
        #expect(vm.isLocked == false)
    }

    @Test func sendBecomesSentWhenTheDaemonQueuesTheReplyNeverDelivered() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard method == "reply.submit", let id,
                  let reply = try? JSONDecoder().decode(SubmitEnvelope.self, from: line).params
            else { return nil }
            return jsonRPCOK(id: id, result: replyResultJSON(id: "reply_1", replyId: "reply_1", idempotencyKey: reply.idempotencyKey, state: "queued"))
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let vm = DeliveryStateViewModel(coordinator: makeCoordinator(client: client), client: client)
        let outcome = await vm.send(reply())

        #expect(outcome == .sent, "a queued reply is only sent, not confirmed delivered (AC 8) - got \(outcome)")
        #expect(vm.state == .sent)
        await client.stop()
    }

    @Test func sendBecomesFailedWhenTheOwningSessionIsAlreadyEnded() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard method == "reply.submit", let id,
                  let reply = try? JSONDecoder().decode(SubmitEnvelope.self, from: line).params
            else { return nil }
            return jsonRPCOK(id: id, result: replyResultJSON(id: "reply_2", replyId: "reply_2", idempotencyKey: reply.idempotencyKey, state: "failed"))
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let vm = DeliveryStateViewModel(coordinator: makeCoordinator(client: client), client: client)
        let outcome = await vm.send(reply())

        #expect(outcome == .failed(replyId: "reply_2"), "a reply the daemon marks failed at submit time must never show as delivered (AC 8)")
        #expect(vm.state == .failed(replyId: "reply_2"))
        await client.stop()
    }

    @Test func sendBecomesOfflineWhenTheSocketIsUnreachable() async throws {
        // No server listening at this path at all.
        let client = KnockClient(socketPath: makeTempSocketPath(), backoffSchedule: [0.02])
        let vm = DeliveryStateViewModel(coordinator: makeCoordinator(client: client), client: client)

        let outcome = await vm.send(reply())

        #expect(outcome == .offline, "an unreachable daemon must never show as delivered (AC 8)")
        #expect(vm.state == .offline)
    }

    /// WAG-349: the daemon answered with an error. The service is up, so the banner must not say offline.
    @Test func sendIsRefusedWhenTheDaemonAnswersWithAnError() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, _ in
            guard method == "reply.submit", let id else { return nil }
            return Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32602,"message":"comments.0.rect.h: Too big"}}"#.utf8)
        }
        try server.start()
        defer { server.stop() }
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let store = PendingReplyStore(environment: ["KNOCK_HOME": tempHome()])
        let vm = DeliveryStateViewModel(coordinator: SendCoordinator(client: client, store: store), client: client)
        let outcome = await vm.send(reply())

        #expect(outcome == .refused(reason: "comments.0.rect.h: Too big"))
        #expect(outcome != .offline)
        #expect(store.load(caseId: "c1") != nil, "kept for Retry with the same key")
        await client.stop()
    }

    /// WAG-349: a saved reply with an out-of-range rect goes out clamped, on Retry after a refusal too.
    @Test func retrySendsASavedReplyWithItsRectClamped() async throws {
        let socketPath = makeTempSocketPath()
        let received = LockedStrings()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard method == "reply.submit", let id,
                  let params = try? JSONDecoder().decode(SubmitEnvelope.self, from: line).params
            else { return nil }
            var heights: [String] = []
            for comment in params.comments { heights.append("\(comment.rect.h)") }
            received.append(heights.joined(separator: ","))
            return jsonRPCOK(id: id, result: replyResultJSON(id: "reply_4", replyId: "reply_4", idempotencyKey: params.idempotencyKey, state: "queued"))
        }
        try server.start()
        defer { server.stop() }
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let bad = Comment(id: "m1", captureId: "cap1", n: 1, rect: Rect(x: 0.0055, y: 0, w: 0.389, h: 1.0000000000000002), text: "x")
        let attempt = PendingReply(caseId: "c1", idempotencyKey: "key-1", choice: nil, message: nil, comments: [bad], captures: [])
        let vm = DeliveryStateViewModel(coordinator: makeCoordinator(client: client), client: client)
        let outcome = await vm.send(attempt)

        #expect(outcome == .sent)
        #expect(received.values == ["1.0"], "h = 1.0000000000000002 goes out as 1")
        await client.stop()
    }

    /// Operator, 4 Oct: a large reply reached the agent while the banner
    /// still said "Sending your answer". A submit whose response times out
    /// checks `cases.list`; a case that already holds the answer is `.sent`,
    /// and the saved copy is dropped so it is never sent again.
    @Test func timedOutSendIsSentWhenTheDaemonAlreadyHasTheReply() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, _ in
            guard method == "cases.list", let id else { return nil } // reply.submit never answers
            return jsonRPCOK(id: id, result: "[\(answeredCaseJSON)]")
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let home = tempHome()
        let store = PendingReplyStore(environment: ["KNOCK_HOME": home])
        let coordinator = SendCoordinator(client: client, store: store, submitTimeout: .milliseconds(200))
        let vm = DeliveryStateViewModel(coordinator: coordinator, client: client)
        let outcome = await vm.send(reply())

        #expect(outcome == .sent)
        #expect(store.load(caseId: "c1") == nil, "the reply landed, so nothing is left to resend")
        await client.stop()
    }

    @Test func timedOutSendStaysOfflineWhenTheDaemonDoesNotHaveTheReply() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, _ in
            guard method == "cases.list", let id else { return nil }
            return jsonRPCOK(id: id, result: "[]")
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let store = PendingReplyStore(environment: ["KNOCK_HOME": tempHome()])
        let coordinator = SendCoordinator(client: client, store: store, submitTimeout: .milliseconds(200))
        let vm = DeliveryStateViewModel(coordinator: coordinator, client: client)
        let outcome = await vm.send(reply())

        #expect(outcome == .offline)
        #expect(store.load(caseId: "c1") != nil, "kept for Retry with the same key")
        await client.stop()
    }

    @Test func retryFromOfflineResubmitsWithTheSameIdempotencyKeyAndNeverTwice() async throws {
        // Starts offline, exactly like `sendBecomesOfflineWhenTheSocketIsUnreachable`.
        let socketPath = makeTempSocketPath()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        let vm = DeliveryStateViewModel(coordinator: makeCoordinator(client: client), client: client)
        let attempt = reply(key: "key-offline")

        let firstOutcome = await vm.send(attempt)
        #expect(firstOutcome == .offline)

        // The daemon comes back; retry should re-submit under the same key.
        let receivedKeys = LockedStrings()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard method == "reply.submit", let id,
                  let received = try? JSONDecoder().decode(SubmitEnvelope.self, from: line).params
            else { return nil }
            receivedKeys.append(received.idempotencyKey)
            return jsonRPCOK(id: id, result: replyResultJSON(id: "reply_3", replyId: "reply_3", idempotencyKey: received.idempotencyKey, state: "queued"))
        }
        try server.start()
        defer { server.stop() }
        await client.start()
        try await waitForState(client, .connected)

        let outcome = await vm.retry()

        #expect(outcome == .sent, "the offline retry's queued outcome is sent, not delivered (AC 8) - got \(outcome)")
        #expect(receivedKeys.values == ["key-offline"], "retry must reuse the original idempotency key, never mint a second reply")
        await client.stop()
    }

    @Test func retryFromFailedCallsReplyRetryRatherThanSubmittingAgain() async throws {
        let socketPath = makeTempSocketPath()
        let methodsSeen = LockedStrings()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            methodsSeen.append(method)
            guard let id else { return nil }
            switch method {
            case "reply.submit":
                guard let received = try? JSONDecoder().decode(SubmitEnvelope.self, from: line).params else { return nil }
                return jsonRPCOK(id: id, result: replyResultJSON(id: "reply_4", replyId: "reply_4", idempotencyKey: received.idempotencyKey, state: "failed"))
            case "reply.retry":
                return jsonRPCOK(id: id, result: replyResultJSON(id: "reply_4", replyId: "reply_4", idempotencyKey: "key-1", state: "queued"))
            default:
                return nil
            }
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let vm = DeliveryStateViewModel(coordinator: makeCoordinator(client: client), client: client)
        let sendOutcome = await vm.send(reply())
        #expect(sendOutcome == .failed(replyId: "reply_4"))

        let retryOutcome = await vm.retry()

        #expect(retryOutcome == .sent, "reply.retry requeuing it is sent, not delivered (AC 8) - got \(retryOutcome)")
        #expect(methodsSeen.values == ["reply.submit", "reply.retry"], "a failed reply's Retry must call reply.retry, not submit a second reply")
        await client.stop()
    }

    @Test func retryFromFailedStaysFailedWhenTheSessionIsStillEnded() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard let id else { return nil }
            switch method {
            case "reply.submit":
                guard let received = try? JSONDecoder().decode(SubmitEnvelope.self, from: line).params else { return nil }
                return jsonRPCOK(id: id, result: replyResultJSON(id: "reply_5", replyId: "reply_5", idempotencyKey: received.idempotencyKey, state: "failed"))
            case "reply.retry":
                return jsonRPCOK(id: id, result: replyResultJSON(id: "reply_5", replyId: "reply_5", idempotencyKey: "key-1", state: "failed"))
            default:
                return nil
            }
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let vm = DeliveryStateViewModel(coordinator: makeCoordinator(client: client), client: client)
        _ = await vm.send(reply())

        let retryOutcome = await vm.retry()

        #expect(retryOutcome == .failed(replyId: "reply_5"), "AC 8: still-unreachable after Retry must stay failed, never delivered")
        await client.stop()
    }
}

/// A tiny thread-safe accumulator, matching `SendCoordinatorTests`'s
/// `LockedArray` - `FakeKnockServer.onRequest` runs on its own background
/// accept thread, so a plain `[String]` capture would race.
private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// `DeliveryState.footerDeliveredLine` (docs/stories/HAIL-32.md state 3): a
/// pure formatter, so the exact copy the case pane footer collapses to is
/// unit-testable without a SwiftUI host.
struct DeliveryStateFooterLineTests {
    @Test func footerDeliveredLineIsTheExactCollapsedCopy() {
        let at = Date(timeIntervalSince1970: 1_800_000_000) // a fixed instant
        let expected = "Delivered ✓ \(KnockDateFormat.dateTime(from: at)) · your reply is with the agent"
        #expect(DeliveryState.delivered(at: at).footerDeliveredLine == expected)
    }

    @Test func footerDeliveredLineIsNilForEveryOtherState() {
        #expect(DeliveryState.idle.footerDeliveredLine == nil)
        #expect(DeliveryState.sending.footerDeliveredLine == nil)
        #expect(DeliveryState.sent.footerDeliveredLine == nil)
        #expect(DeliveryState.offline.footerDeliveredLine == nil)
        #expect(DeliveryState.failed(replyId: "r_1").footerDeliveredLine == nil)
    }
}
