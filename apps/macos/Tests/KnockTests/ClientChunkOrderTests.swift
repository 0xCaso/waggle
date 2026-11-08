import Testing
import Foundation
@testable import Knock

/// HAIL-120: a big `cases.list` answer arrives in many chunks. Chunks handled out of order
/// garbled the line, the request timed out, and the queue stayed stale. On main about 1 call
/// in 8 failed this way.
struct ClientChunkOrderTests {
    @Test func bigListsDecodeEveryTime() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let one = #"{"id":"c_X","task_id":"t_1","kind":"review","title":"Checkout layout","need":"Pick A or B.","why":"Both meet spec.","recommendation":"a","recommendation_why":"68%","options":[],"status":"needs_you","has_artifact":true,"runtime":"claude","created_at":"2026-09-26T10:00:00Z","updated_at":"2026-09-26T10:41:00Z"}"#
        let big = "[" + (0..<1200).map { one.replacingOccurrences(of: "c_X", with: "c_\($0)") }.joined(separator: ",") + "]"
        server.onRequest = { method, id, _ in
            guard method == "cases.list", let id else { return nil }
            return jsonRPCOK(id: id, result: big)
        }
        try server.start()
        defer { server.stop() }
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        var failures = 0
        for _ in 0..<60 {
            do {
                let cases = try await client.casesList(status: .needsYou)
                if cases.count != 1200 { failures += 1 }
            } catch { failures += 1 }
        }
        await client.stop()
        #expect(failures == 0, "failures: \(failures)")
    }
}
