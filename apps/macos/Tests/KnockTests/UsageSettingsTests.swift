import Testing
import Foundation
@testable import Knock

/// HAIL-195: the Usage section of Settings › Data & privacy.
struct UsageSettingsTests {
    private static let summaryJSON = #"""
    {"days":7,"record":true,"transcript":true,"retention_days":90,"calls":3,
     "tokens_written":120,"tokens_received":4000,"context_tokens":900000,"context_measured_calls":2,
     "tools":[{"tool":"waggle_check","calls":2,"tokens_written":20,"tokens_received":300,
               "context_tokens":900000,"waited_s":600},
              {"tool":"waggle_ask","calls":1,"tokens_written":100,"tokens_received":3700,
               "context_tokens":0,"waited_s":0}],
     "wait_calls":2,"wait_share":0.8,"waited_s":600,
     "top_sessions":[{"session_id":"abc","client_name":"claude-code","calls":3,"tokens":904120}],
     "tokens_per_image":1600,"bytes_per_token":4}
    """#

    private func summary() throws -> UsageSummary {
        try JSONDecoder().decode(UsageSummary.self, from: Data(Self.summaryJSON.utf8))
    }

    @Test func decodesTheDaemonSummary() throws {
        let s = try summary()
        #expect(s.calls == 3)
        #expect(s.tools.map(\.tool) == ["waggle_check", "waggle_ask"])
        #expect(s.waitShare == 0.8)
        #expect(s.topSessions.first?.clientName == "claude-code")
        #expect(s.retentionDays == 90)
    }

    @Test func formatsShareAndLinesWithoutMoney() throws {
        let s = try summary()
        #expect(UsageText.share(0.623) == "62%")
        #expect(UsageText.share(nil) == "-")
        #expect(UsageText.totalLine(s) == "3 calls · \(UsageText.tokens(904_120)) tokens · last 7 days")
        #expect(UsageText.waitLine(s) == "2 checks · 80% of the tokens · 10 min waiting for you")
        #expect(UsageText.toolLine(s.tools[1]) == "1 call · 100 written · \(UsageText.tokens(3700)) received")
        #expect(UsageText.sessionLine(s.topSessions[0]) == "claude-code · 3 calls · \(UsageText.tokens(904_120)) tokens")
        #expect(UsageText.estimateLine(s).contains("\(UsageText.tokens(1600)) tokens per image"))
    }

    @Test func noTextShowsDollarsOrPrices() throws {
        let s = try summary()
        var texts = [UsageText.inside, UsageText.estimateLine(s), UsageText.totalLine(s), UsageText.waitLine(s)]
        texts += s.tools.map(UsageText.toolLine) + s.topSessions.map(UsageText.sessionLine)
        for text in texts {
            #expect(!text.contains("$"))
            #expect(!text.contains("—"))
            #expect(!text.lowercased().contains("cost"))
            #expect(!text.lowercased().contains("price"))
        }
    }

    @Test func exportFileNameIsDated() {
        let date = Date(timeIntervalSince1970: 1_791_284_214)
        #expect(UsageText.exportFileName(on: date).hasPrefix("waggle-usage-20"))
        #expect(UsageText.exportFileName(on: date).hasSuffix(".json"))
    }

    @Test func controlParamsSendOnlyWhatIsSet() throws {
        let data = try JSONEncoder().encode(UsageControlParams(transcript: false))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json == #"{"transcript":false}"#)
    }

    @MainActor
    @Test func modelLoadsTheSummaryAndSendsSwitchChanges() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let seen = LockedList()
        server.onRequest = { method, id, line in
            guard let id else { return nil }
            switch method {
            case "usage.summary":
                return jsonRPCOK(id: id, result: Self.summaryJSON)
            case "usage.control":
                seen.append(String(decoding: line, as: UTF8.self))
                return jsonRPCOK(
                    id: id,
                    result: #"{"record":false,"transcript":true,"retention_days":90,"tool_calls":0,"usage_events":0,"deleted":0}"#
                )
            default:
                return nil
            }
        }
        try server.start()
        defer { server.stop() }
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02, 0.02, 0.05])
        await client.start()
        try await waitForState(client, .connected)

        let model = UsageSettingsModel(client: client, pollInterval: .seconds(60))
        await model.load()
        #expect(model.summary?.calls == 3)
        await model.setRecord(false)
        #expect(seen.items.count == 1)
        #expect(seen.items[0].contains(#""record":false"#))
        #expect(!seen.items[0].contains("transcript"))
        await client.stop()
    }
}

private final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var items: [String] { lock.lock(); defer { lock.unlock() }; return values }
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
}
