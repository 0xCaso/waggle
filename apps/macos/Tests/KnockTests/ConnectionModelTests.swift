import Combine
import Testing
import Foundation
@testable import Knock

/// HAIL-46: the Connection screen's list model. `pollInterval` is set far
/// longer than the test itself so these assertions exercise the initial
/// `start()` fetch deterministically, without racing a background poll tick.
@MainActor
struct ConnectionModelTests {
    @Test func startPopulatesSessionsFromTheDaemon() async throws {
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

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let model = ConnectionModel(client: client, pollInterval: .seconds(60))
        #expect(model.sessions.isEmpty)

        await model.start()

        #expect(model.sessions.count == 1)
        #expect(model.sessions.first?.id == "s_1")
        #expect(model.sessions.first?.state == .live)

        await client.stop()
    }

    @Test func noSessionsReadsAsAnEmptyList() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, _ in
            guard method == "sessions.list", let id else { return nil }
            return jsonRPCOK(id: id, result: "[]")
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let model = ConnectionModel(client: client, pollInterval: .seconds(60))
        await model.start()

        #expect(model.sessions.isEmpty)

        await client.stop()
    }

    nonisolated private static func sessionsServer(path: String, liveIds: [String]) -> FakeKnockServer {
        let server = FakeKnockServer(socketPath: path)
        server.onRequest = { method, id, _ in
            guard method == "sessions.list", let id else { return nil }
            let rows = liveIds.map {
                #"{"id":"\#($0)","runtime":"claude","task_name":"knock","project":"knock","branch":"main","state":"live","connected_at":"2026-09-26T10:00:00Z","last_seen_at":"2026-09-26T10:41:00Z"}"#
            }
            return jsonRPCOK(id: id, result: "[" + rows.joined(separator: ",") + "]")
        }
        return server
    }

    private func waitUntil(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        _ = try await pollUntil(timeout, every: .milliseconds(20), condition)
    }

    /// HAIL-105: the footer's count must follow the daemon across a restart. The
    /// model polls through the same client, which reconnects on its own.
    @Test func countRecoversAfterTheDaemonRestarts() async throws {
        let socketPath = makeTempSocketPath()
        let first = Self.sessionsServer(path: socketPath, liveIds: ["a", "b"])
        try first.start()

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02], startDaemon: {})
        await client.start()
        try await waitForState(client, .connected)
        let model = ConnectionModel(client: client, pollInterval: .milliseconds(50))
        await model.start()
        #expect(model.liveSessions.count == 2)

        first.stop()
        try await Task.sleep(for: .milliseconds(300))
        let second = Self.sessionsServer(path: socketPath, liveIds: ["a", "b", "c", "d"])
        try second.start()
        defer { second.stop() }

        try await waitUntil { model.liveSessions.count == 4 }
        #expect(model.liveSessions.count == 4)
        await client.stop()
    }

    /// HAIL-105: a failed read does not stop the model. It keeps the last list,
    /// says it failed, and tries again after the short retry, not a full poll.
    @Test func failedReadKeepsTheListAndRetriesQuickly() async throws {
        let socketPath = makeTempSocketPath()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02], startDaemon: {})
        await client.start()
        let model = ConnectionModel(
            client: client, pollInterval: .seconds(60), retryInterval: .milliseconds(50))
        await model.start()
        #expect(model.lastRefreshFailed)
        #expect(model.liveSessions.isEmpty)

        let server = Self.sessionsServer(path: socketPath, liveIds: ["a", "b", "c"])
        try server.start()
        defer { server.stop() }

        try await waitUntil { model.liveSessions.count == 3 }
        #expect(model.liveSessions.count == 3)
        #expect(!model.lastRefreshFailed)
        await client.stop()
    }

    /// Issue 9: a poll that reads the same list does not publish `sessions` again, so the views that read it
    /// do not re-render.
    @Test func theSameListIsNotPublishedAgain() async throws {
        let socketPath = makeTempSocketPath()
        let server = Self.sessionsServer(path: socketPath, liveIds: ["a", "b"])
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        let model = ConnectionModel(client: client, pollInterval: .seconds(60))
        await model.start()
        #expect(model.sessions.count == 2)

        var sends = 0
        let watch = model.$sessions.dropFirst().sink { _ in sends += 1 }
        await model.refresh()
        await model.refresh()
        #expect(sends == 0)
        watch.cancel()
        await client.stop()
    }

    /// A failed read still moves the clock, so the footer count and the durations do not freeze while the
    /// daemon is down.
    @Test func aFailedReadMovesTheClock() async throws {
        let client = KnockClient(socketPath: makeTempSocketPath(), backoffSchedule: [0.02], startDaemon: {})
        await client.start()
        let model = ConnectionModel(client: client, pollInterval: .seconds(60), retryInterval: .seconds(60))
        await model.start()
        #expect(model.lastRefreshFailed)
        let before = model.now
        try await Task.sleep(for: .milliseconds(20))
        await model.refresh()
        #expect(model.now > before)
        await client.stop()
    }
}
