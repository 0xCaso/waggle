import Testing
import Foundation
@testable import Knock

enum TestClientError: Error {
    case timedOut
}

/// Waits for `client.connectionStates` to yield `target`, or fails after
/// `timeout`.
func waitForState(_ client: KnockClient, _ target: KnockClient.ConnectionState, timeout: Duration = .seconds(15)) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            for await state in client.connectionStates {
                if state == target { return }
            }
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TestClientError.timedOut
        }
        try await group.next()
        group.cancelAll()
    }
}

/// Builds a one-line JSON-RPC success response. The wire protocol is one
/// JSON object per line (docs/protocol-mvp.md "Socket RPC"), so any literal
/// newline inside a pretty-printed `result` fixture must be collapsed first,
/// or it reads back as multiple broken lines.
func jsonRPCOK(id: Int, result: String) -> Data {
    let oneLine = result.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined()
    return Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(oneLine)}"#.utf8)
}

/// A thread-safe counter for a `@Sendable` closure captured by `KnockClient`.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int {
        get { lock.lock(); defer { lock.unlock() }; return _count }
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }
        _count += 1
    }
}

struct KnockClientTests {
    @Test func connectsAndDecodesCasesList() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, _ in
            guard method == "cases.list", let id else { return nil }
            let resultJSON = #"""
            [{"id":"c_1","task_id":"t_1","kind":"review","title":"Checkout layout",
              "need":"Pick A or B.","why":"Both meet spec.","recommendation":"a",
              "recommendation_why":"68%...","options":[],"status":"needs_you",
              "has_artifact":true,"runtime":"claude","created_at":"2026-09-26T10:00:00Z",
              "updated_at":"2026-09-26T10:41:00Z"}]
            """#
            return jsonRPCOK(id: id, result: resultJSON)
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02, 0.02, 0.05])
        await client.start()
        try await waitForState(client, .connected)

        let cases = try await client.casesList()
        #expect(cases.count == 1)
        #expect(cases.first?.id == "c_1")
        #expect(cases.first?.status == .needsYou)

        await client.stop()
    }

    // HAIL-46: sessions.list backs the Connection screen.
    @Test func connectsAndDecodesSessionsList() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, _ in
            guard method == "sessions.list", let id else { return nil }
            let resultJSON = #"""
            [{"id":"s_1","runtime":"claude","task_name":"knock","project":"knock",
              "branch":"main","state":"live","connected_at":"2026-09-26T10:00:00Z",
              "last_seen_at":"2026-09-26T10:41:00Z"}]
            """#
            return jsonRPCOK(id: id, result: resultJSON)
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02, 0.02, 0.05])
        await client.start()
        try await waitForState(client, .connected)

        let sessions = try await client.sessionsList()
        #expect(sessions.count == 1)
        #expect(sessions.first?.id == "s_1")
        #expect(sessions.first?.state == .live)

        await client.stop()
    }

    @Test func surfacesJSONRPCErrorsAsThrownErrors() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, _ in
            guard method == "cases.get", let id else { return nil }
            let json = #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"no such case"}}"#
            return Data(json.utf8)
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        await #expect(throws: JSONRPCErrorPayload.self) {
            _ = try await client.casesGet(id: "missing")
        }

        await client.stop()
    }

    @Test func receivesPushedEventNotifications() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { _, id, _ in
            guard let id else { return nil }
            return jsonRPCOK(id: id, result: "{}")
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        try await client.subscribeEvents()

        server.pushEvent(Event(type: .caseCreated, caseId: "c_1", replyId: nil, sessionId: nil, at: "2026-09-26T10:00:00Z"))

        let received = try await withThrowingTaskGroup(of: Event?.self) { group -> Event? in
            group.addTask {
                for await event in client.events { return event }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                return nil
            }
            let result = try await group.next()
            group.cancelAll()
            return result ?? nil
        }

        #expect(received?.caseId == "c_1")
        #expect(received?.type == .caseCreated)

        await client.stop()
    }

    @Test func reconnectsAfterServerDisconnectsIt() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { _, id, _ in
            guard let id else { return nil }
            return jsonRPCOK(id: id, result: "{}")
        }
        try server.start()
        defer { server.stop() }

        // Fast schedule: this test does not exercise the real 1s/2s/5s
        // timing (that would make the suite slow); it exercises that the
        // loop reconnects at all, using injected short delays.
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02, 0.02, 0.02])
        await client.start()
        try await waitForState(client, .connected)

        server.disconnectClient()
        try await waitForState(client, .disconnected)
        try await waitForState(client, .connected)

        // The connection is usable again after reconnecting.
        try await client.subscribeEvents()

        await client.stop()
    }

    @Test func startsTheDaemonOnDemandWhenTheSocketIsUnreachable() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { _, id, _ in
            guard let id else { return nil }
            return jsonRPCOK(id: id, result: "{}")
        }
        // Deliberately not started: the client's connect path must start it.

        let starts = CallCounter()
        let client = KnockClient(
            socketPath: socketPath,
            backoffSchedule: [0.02],
            startDaemon: {
                starts.increment()
                try? server.start()
            }
        )
        await client.start()
        try await waitForState(client, .connected, timeout: .seconds(15))

        #expect(starts.count == 1)
        try await client.subscribeEvents()

        await client.stop()
        server.stop()
    }

    @Test func stopEndsTheReconnectLoop() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { _, id, _ in
            guard let id else { return nil }
            return jsonRPCOK(id: id, result: "{}")
        }
        try server.start()

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        await client.stop()
        server.stop()

        // No further connection attempts should occur; give it a moment and
        // confirm the state stays disconnected.
        try await Task.sleep(for: .milliseconds(100))
        // Calling a method after stop should fail, not hang.
        await #expect(throws: (any Error).self) {
            _ = try await client.serviceStatus()
        }
    }

    @Test func usageRecordSendsTheEventAndSource() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let captured = CapturedLine()
        server.onRequest = { method, id, line in
            guard method == "usage.record", let id else { return nil }
            captured.data = line
            return jsonRPCOK(id: id, result: "{}")
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        try await client.usageRecord(event: .caseOpened, source: .queue)

        let raw = try #require(captured.data)
        let peek = try JSONDecoder().decode(UsageRequestPeek.self, from: raw)
        #expect(peek.method == "usage.record")
        #expect(peek.params.event == "case_opened")
        #expect(peek.params.source == "queue")

        await client.stop()
    }

    @Test func serviceRestartSendsTheRestartMethod() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let captured = CapturedLine()
        server.onRequest = { method, id, line in
            guard method == "service.restart", let id else { return nil }
            captured.data = line
            return jsonRPCOK(id: id, result: "{}")
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        try await client.serviceRestart()

        let raw = try #require(captured.data)
        let peek = try JSONDecoder().decode(MethodPeek.self, from: raw)
        #expect(peek.method == "service.restart")

        await client.stop()
    }

    /// AC: "Every KnockClient request has a timeout ... On a timeout the
    /// call throws". The server accepts the connection but never answers, so
    /// nothing but the injected timeout can end this call.
    @Test func aRequestThatNeverGetsAResponseThrowsOnItsTimeoutRatherThanHanging() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { _, _, _ in nil }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        await #expect(throws: KnockClient.ClientError.timeout) {
            let _: EmptyResult = try await client.call("cases.list", params: EmptyParams(), timeout: .milliseconds(100))
        }

        await client.stop()
    }

    @Test func commentModeUsageRecordOmitsTheSource() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let captured = CapturedLine()
        server.onRequest = { method, id, line in
            guard method == "usage.record", let id else { return nil }
            captured.data = line
            return jsonRPCOK(id: id, result: "{}")
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        try await client.usageRecord(event: .commentModeStarted)

        let raw = try #require(captured.data)
        let peek = try JSONDecoder().decode(UsageRequestPeek.self, from: raw)
        #expect(peek.params.event == "comment_mode_started")
        #expect(peek.params.source == nil)

        await client.stop()
    }
}

private struct UsageRequestPeek: Decodable {
    let method: String
    let params: UsageParamsPeek
}

private struct MethodPeek: Decodable {
    let method: String
}

private struct UsageParamsPeek: Decodable {
    let event: String
    let source: String?
}

/// A thread-safe box for a line the fake server received on a background
/// thread, mirroring the `CallCounter` pattern above.
private final class CapturedLine: @unchecked Sendable {
    private let lock = NSLock()
    private var _data: Data?
    var data: Data? {
        get { lock.lock(); defer { lock.unlock() }; return _data }
        set { lock.lock(); defer { lock.unlock() }; _data = newValue }
    }
}
