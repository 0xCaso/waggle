import Testing
import Foundation
@testable import Knock

private struct RequestEnvelope: Decodable { let params: PendingReply }

/// `line` is the full JSON-RPC request line (`{"id","method","params"}`);
/// the wire `reply.submit` params share `PendingReply`'s exact key names
/// (`case_id`, `idempotency_key`, ...), so decoding `params` straight into it
/// round-trips what the client actually sent. A free function, not a method
/// on the (`@MainActor`) test type, since `FakeKnockServer` calls
/// `onRequest` from its own background accept thread.
private func decodeReply(from line: Data) -> PendingReply? {
    try? JSONDecoder().decode(RequestEnvelope.self, from: line).params
}

private func replyResultJSON(id: String, reply: PendingReply) -> String {
    #"""
    {"id":"\#(id)","case_id":"\#(reply.caseId)","idempotency_key":"\#(reply.idempotencyKey)",
     "choice":\#(reply.choice.map { "\"\($0)\"" } ?? "null"),
     "message":\#(reply.message.map { "\"\($0)\"" } ?? "null"),
     "comments":[],"captures":[],"state":"queued","created_at":"2026-09-26T10:00:00Z"}
    """#
}

/// `SendCoordinator`: the idempotency-key lifecycle and the offline queue
/// (docs/protocol-mvp.md: "the app keeps the unsent reply locally ... On
/// reconnect it re-submits with the same key").
///
/// `.serialized`: several of these tests spin up their own real
/// `FakeKnockServer` (a unix socket plus a background accept `Thread`) and a
/// real `KnockClient`. Running them concurrently with each other piled up
/// enough sockets/threads to make the suite hang intermittently; one at a
/// time is plenty fast and reliable.
@Suite(.serialized)
@MainActor
struct SendCoordinatorTests {
    private func tempHome() -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("knock_send_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    @Test func idempotencyKeyIsFreshWhenNothingIsPending() {
        let store = PendingReplyStore(environment: ["KNOCK_HOME": tempHome()])
        let client = KnockClient(socketPath: makeTempSocketPath())
        let coordinator = SendCoordinator(client: client, store: store)

        let first = coordinator.idempotencyKey(for: "c_1")
        let second = coordinator.idempotencyKey(for: "c_1")

        #expect(first != second, "no reply saved yet for c_1, so each call mints its own - the caller is responsible for saving before asking again")
    }

    @Test func idempotencyKeyReusesAnAlreadyPendingReplysKey() throws {
        let store = PendingReplyStore(environment: ["KNOCK_HOME": tempHome()])
        let client = KnockClient(socketPath: makeTempSocketPath())
        let coordinator = SendCoordinator(client: client, store: store)

        let key = coordinator.idempotencyKey(for: "c_1")
        try store.save(PendingReply(caseId: "c_1", idempotencyKey: key, choice: nil, message: "hi", comments: [], captures: []))

        #expect(coordinator.idempotencyKey(for: "c_1") == key, "a retry or a reconnect resubmit must reuse the same key, never mint a second one")
    }

    @Test func sendRemovesThePendingCopyOnceTheDaemonConfirms() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard method == "reply.submit", let id, let reply = decodeReply(from: line) else { return nil }
            return jsonRPCOK(id: id, result: replyResultJSON(id: "r_1", reply: reply))
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let store = PendingReplyStore(environment: ["KNOCK_HOME": tempHome()])
        let coordinator = SendCoordinator(client: client, store: store)
        let reply = PendingReply(caseId: "c_1", idempotencyKey: "key-1", choice: "a", message: nil, comments: [], captures: [])

        let result = try await coordinator.send(reply)

        #expect(result.id == "r_1")
        #expect(store.load(caseId: "c_1") == nil, "delivered (or queued-but-accepted) replies are not kept locally any more")
        await client.stop()
    }

    @Test func sendKeepsThePendingCopyWhenTheSocketIsUnreachable() async throws {
        // No server listening at this path at all.
        let client = KnockClient(socketPath: makeTempSocketPath(), backoffSchedule: [0.02])
        let store = PendingReplyStore(environment: ["KNOCK_HOME": tempHome()])
        let coordinator = SendCoordinator(client: client, store: store)
        let reply = PendingReply(caseId: "c_1", idempotencyKey: "key-1", choice: "a", message: nil, comments: [], captures: [])

        await #expect(throws: (any Error).self) {
            _ = try await coordinator.send(reply)
        }

        #expect(store.load(caseId: "c_1") == reply, "AC: kept locally while the socket is down")
    }

    @Test func resubmitPendingDeliversEverySavedReplyAndClearsThem() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let receivedCaseIds = LockedArray()
        server.onRequest = { method, id, line in
            guard method == "reply.submit", let id, let reply = decodeReply(from: line) else { return nil }
            receivedCaseIds.append(reply.caseId)
            return jsonRPCOK(id: id, result: replyResultJSON(id: "r_\(reply.caseId)", reply: reply))
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let store = PendingReplyStore(environment: ["KNOCK_HOME": tempHome()])
        try store.save(PendingReply(caseId: "c_1", idempotencyKey: "key-1", choice: "a", message: nil, comments: [], captures: []))
        try store.save(PendingReply(caseId: "c_2", idempotencyKey: "key-2", choice: nil, message: "hi", comments: [], captures: []))

        let coordinator = SendCoordinator(client: client, store: store)
        await coordinator.resubmitPending()

        #expect(Set(receivedCaseIds.values) == ["c_1", "c_2"])
        #expect(store.loadAll().isEmpty)
        await client.stop()
    }

    /// AC: "A pending reply is deleted ... also when the daemon returns an
    /// existing reply for that idempotency key" - the server here always
    /// answers with the same reply id/state regardless of how many times the
    /// same idempotency key arrives, standing in for the daemon's own dedup
    /// (docs/protocol-mvp.md: "reply.submit with an existing idempotency_key
    /// returns the existing reply"). `send`'s cleanup does not distinguish a
    /// fresh `queued` result from a dedup'd one - both are "the daemon has
    /// this reply" - so this exercises the same code path as
    /// `sendRemovesThePendingCopyOnceTheDaemonConfirms`, named for the bullet
    /// it proves.
    @Test func resubmitDeletesPendingWhenDaemonReturnsAnExistingReplyForTheIdempotencyKey() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard method == "reply.submit", let id, let reply = decodeReply(from: line) else { return nil }
            return jsonRPCOK(id: id, result: replyResultJSON(id: "r_existing", reply: reply))
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let store = PendingReplyStore(environment: ["KNOCK_HOME": tempHome()])
        try store.save(PendingReply(caseId: "c_1", idempotencyKey: "key-1", choice: "a", message: nil, comments: [], captures: []))

        let coordinator = SendCoordinator(client: client, store: store)
        await coordinator.resubmitPending()

        #expect(store.load(caseId: "c_1") == nil)
        await client.stop()
    }

    /// AC: "It is also deleted when its case is no longer needs_you: its
    /// status is waiting_on_agent or resolved, and latest_reply_id is set" -
    /// the exact operator scenario (a pending file for a case already
    /// `waiting_on_agent` with its reply delivered). No server is started at
    /// all: `knownCases` alone must be enough to clean this up without ever
    /// attempting `reply.submit`.
    @Test func resubmitDeletesPendingWithoutResendingWhenItsKnownCaseIsAlreadyAnswered() async throws {
        let client = KnockClient(socketPath: makeTempSocketPath(), backoffSchedule: [0.02])
        let store = PendingReplyStore(environment: ["KNOCK_HOME": tempHome()])
        try store.save(PendingReply(caseId: "c_1", idempotencyKey: "key-1", choice: "a", message: nil, comments: [], captures: []))

        let alreadyAnswered = Case(
            id: "c_1", taskId: "t_1", kind: .review, title: "T", need: "N", why: "W",
            recommendation: "R", recommendationWhy: "RW", options: [], status: .waitingOnAgent,
            hasArtifact: false, latestReplyId: "r_1", latestReplyState: .delivered,
            createdAt: "2026-09-26T09:00:00.000Z", updatedAt: "2026-09-26T09:00:00.000Z"
        )

        let coordinator = SendCoordinator(client: client, store: store)
        await coordinator.resubmitPending(knownCases: [alreadyAnswered])

        #expect(store.load(caseId: "c_1") == nil, "the known case already has a reply; resubmitting must not be required to clean this up")
    }

    /// The same case still `needs_you` (no reply landed yet) must still
    /// resubmit rather than being swept up by the same check.
    @Test func resubmitStillResendsWhenItsKnownCaseIsStillNeedsYou() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let receivedCaseIds = LockedArray()
        server.onRequest = { method, id, line in
            guard method == "reply.submit", let id, let reply = decodeReply(from: line) else { return nil }
            receivedCaseIds.append(reply.caseId)
            return jsonRPCOK(id: id, result: replyResultJSON(id: "r_1", reply: reply))
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let store = PendingReplyStore(environment: ["KNOCK_HOME": tempHome()])
        try store.save(PendingReply(caseId: "c_1", idempotencyKey: "key-1", choice: "a", message: nil, comments: [], captures: []))

        let stillOpen = Case(
            id: "c_1", taskId: "t_1", kind: .review, title: "T", need: "N", why: "W",
            recommendation: "R", recommendationWhy: "RW", options: [], status: .needsYou,
            hasArtifact: false, createdAt: "2026-09-26T09:00:00.000Z", updatedAt: "2026-09-26T09:00:00.000Z"
        )

        let coordinator = SendCoordinator(client: client, store: store)
        await coordinator.resubmitPending(knownCases: [stillOpen])

        #expect(receivedCaseIds.values == ["c_1"])
        #expect(store.load(caseId: "c_1") == nil)
        await client.stop()
    }

    /// AC: "It is also deleted on the unknown-case error -32001" - the case
    /// is gone, so there is nothing left to resend it to.
    @Test func resubmitDeletesPendingOnUnknownCaseError() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, _ in
            guard method == "reply.submit", let id else { return nil }
            let json = #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32001,"message":"case not found"}}"#
            return Data(json.utf8)
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let store = PendingReplyStore(environment: ["KNOCK_HOME": tempHome()])
        try store.save(PendingReply(caseId: "c_gone", idempotencyKey: "key-1", choice: "a", message: nil, comments: [], captures: []))

        let coordinator = SendCoordinator(client: client, store: store)
        await coordinator.resubmitPending()

        #expect(store.load(caseId: "c_gone") == nil)
        await client.stop()
    }

    /// AC: "Each resubmit has a timeout of 15 s" - a server that never
    /// answers `reply.submit` must not leave the pending file's resubmit
    /// hanging forever; the file stays queued for the next reconnect rather
    /// than being lost.
    @Test func resubmitOneTimesOutRatherThanHangingForeverAndLeavesTheFileQueued() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, _ in
            guard method != "reply.submit", let id else { return nil }
            return jsonRPCOK(id: id, result: "{}")
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let store = PendingReplyStore(environment: ["KNOCK_HOME": tempHome()])
        try store.save(PendingReply(caseId: "c_1", idempotencyKey: "key-1", choice: "a", message: nil, comments: [], captures: []))

        let coordinator = SendCoordinator(client: client, store: store)
        let deadline = ContinuousClock.now
        await coordinator.resubmitPending()
        let elapsed = deadline.duration(to: ContinuousClock.now)

        #expect(elapsed < .seconds(20), "resubmitOne's 15s bound must not be exceeded by much")
        #expect(store.load(caseId: "c_1") != nil, "still unanswered: the file stays queued for the next reconnect")
        await client.stop()
    }
}

/// A tiny thread-safe accumulator: `FakeKnockServer.onRequest` runs on its own
/// background accept thread, so a plain `[String]` capture would race.
private final class LockedArray: @unchecked Sendable {
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
