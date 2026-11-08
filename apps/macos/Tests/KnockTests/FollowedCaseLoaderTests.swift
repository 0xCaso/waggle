import Testing
import Foundation
@testable import Knock

/// `FollowedCaseLoader` (HAIL-33 amendment): fetches the earlier ask a
/// follow-up's header links to, once, and caches it in memory.
@MainActor
struct FollowedCaseLoaderTests {
    private func caseJSON(id: String, title: String, choice: String? = nil, message: String? = nil) -> String {
        #"""
        {"id":"\#(id)","task_id":"t_1","kind":"question","title":"\#(title)",
         "need":"N","why":"W","recommendation":"R","recommendation_why":"RW","options":[],
         "status":"waiting_on_agent","has_artifact":false,"runtime":"claude",
         \#(choice != nil ? "\"latest_reply_choice\":\"\(choice!)\"," : "")
         \#(message != nil ? "\"latest_reply_message\":\"\(message!)\"," : "")
         "latest_reply_id":"reply_1",
         "created_at":"2026-09-26T10:00:00Z","updated_at":"2026-09-26T10:00:00Z"}
        """#
    }

    private func caseDetailJSON(_ caseJSON: String) -> String {
        #"""
        {"case":\#(caseJSON),"task":{"id":"t_1","name":"Waggle test","project":"knock"},
         "messages":[],"revisions":[],"comments":[],"replies":[]}
        """#
    }

    @Test func loadFetchesTheFollowedCaseOverCasesGet() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, _ in
            guard let id, method == "cases.get" else { return nil }
            return jsonRPCOK(id: id, result: caseDetailJSON(caseJSON(id: "c_earlier", title: "Change the button color?")))
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let loader = FollowedCaseLoader(client: client, cache: FollowedCaseCache())
        await loader.load(caseId: "c_earlier")

        #expect(loader.followedCase?.id == "c_earlier")
        #expect(loader.followedCase?.title == "Change the button color?")
        await client.stop()
    }

    @Test func aSecondLoadForTheSameIdReusesTheCacheWithoutAnotherRequest() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        var requestCount = 0
        server.onRequest = { method, id, _ in
            guard let id, method == "cases.get" else { return nil }
            requestCount += 1
            return jsonRPCOK(id: id, result: caseDetailJSON(caseJSON(id: "c_earlier", title: "Change the button color?")))
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let sharedCache = FollowedCaseCache()
        let first = FollowedCaseLoader(client: client, cache: sharedCache)
        await first.load(caseId: "c_earlier")
        let second = FollowedCaseLoader(client: client, cache: sharedCache)
        await second.load(caseId: "c_earlier")

        #expect(requestCount == 1, "the second loader should reuse the cached case, not fetch it again")
        #expect(second.followedCase?.id == "c_earlier")
        await client.stop()
    }

    @Test func aFailedFetchLeavesFollowedCaseNil() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, _ in
            guard let id, method == "cases.get" else { return nil }
            return Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32001,"message":"case not found"}}"#.utf8)
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let loader = FollowedCaseLoader(client: client, cache: FollowedCaseCache())
        await loader.load(caseId: "c_missing")

        #expect(loader.followedCase == nil)
        await client.stop()
    }
}
