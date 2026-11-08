import Testing
import Foundation
@testable import Knock

/// HAIL-144: the Phone page model and its connectors.* RPC, the reply source on a case, and the
/// "Answered from Telegram" queue line.
@MainActor
struct PhoneSettingsTests {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
        func add(_ value: String) { lock.lock(); _calls.append(value); lock.unlock() }
    }

    private nonisolated static func status(_ state: String, code: String? = nil, chat: String? = nil) -> String {
        let bot = state == "off" ? "null" : #""Waggle Test Bot""#
        let user = state == "off" ? "null" : #""knock_test_bot""#
        return #"{"state":"\#(state)","bot_name":\#(bot),"bot_username":\#(user),"chat_label":\#(chat.map { "\"\($0)\"" } ?? "null"),"code":\#(code.map { "\"\($0)\"" } ?? "null"),"error":null}"#
    }

    private nonisolated static func slackStatus(_ state: String, code: String? = nil, user: String? = nil) -> String {
        let named = state == "off" ? "null" : #""Acme Inc""#
        return #"{"state":"\#(state)","workspace":\#(named),"bot_name":\#(state == "off" ? "null" : #""knock""#),"user_label":\#(user.map { "\"\($0)\"" } ?? "null"),"code":\#(code.map { "\"\($0)\"" } ?? "null"),"manifest":"{}","error":null}"#
    }

    private func connectedClient(log: Log) async throws -> (KnockClient, FakeKnockServer) {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard let id else { return nil }
            log.add(method)
            switch method {
            case "connectors.status":
                return jsonRPCOK(id: id, result: #"{"telegram":\#(Self.status("off")),"slack":\#(Self.slackStatus("off"))}"#)
            case "connectors.slack.check_tokens":
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                let params = object?["params"] as? [String: Any]
                log.add("slack:\(params?["app_token"] as? String ?? "")|\(params?["bot_token"] as? String ?? "")")
                if params?["bot_token"] as? String == "xoxb-bad" {
                    return Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32010,"message":"Slack did not accept that token. Check it and try again."}}"#.utf8)
                }
                return jsonRPCOK(id: id, result: Self.slackStatus("token_checked"))
            case "connectors.slack.start_pairing":
                return jsonRPCOK(id: id, result: Self.slackStatus("waiting_for_start", code: "XYZ789"))
            case "connectors.slack.send_test":
                return jsonRPCOK(id: id, result: #"{"ok":true}"#)
            case "connectors.slack.disconnect":
                return jsonRPCOK(id: id, result: Self.slackStatus("off"))
            case "connectors.telegram.check_token":
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                let params = object?["params"] as? [String: Any]
                if params?["token"] as? String == "bad" {
                    return Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32010,"message":"Telegram did not accept that token. Check it and try again."}}"#.utf8)
                }
                return jsonRPCOK(id: id, result: Self.status("token_checked"))
            case "connectors.telegram.start_pairing":
                return jsonRPCOK(id: id, result: Self.status("waiting_for_start", code: "ABC234"))
            case "connectors.telegram.send_test":
                return jsonRPCOK(id: id, result: #"{"ok":true}"#)
            case "connectors.telegram.disconnect":
                return jsonRPCOK(id: id, result: Self.status("off"))
            default:
                return nil
            }
        }
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        return (client, server)
    }

    @Test func pageSitsAfterAsksWithPlainCopy() {
        let pages = SettingsPage.allCases
        #expect(pages.firstIndex(of: .phone) == pages.firstIndex(of: .asks)! + 1)
        #expect(SettingsPage.phone.title == "Phone")
        #expect(!SettingsPage.phone.subtitle.contains("—"))
        #expect(SettingsPage.initial(environment: ["KNOCK_SETTINGS_PAGE": "phone"]) == .phone)
    }

    @Test func connectFlowWalksTheFourStates() async throws {
        let log = Log()
        let (client, server) = try await connectedClient(log: log)
        defer { server.stop() }
        let model = PhoneSettingsModel(client: client)
        await model.refresh()
        #expect(model.status.state == .off)

        model.token = "  123:abc  "
        await model.checkToken()
        #expect(model.status.state == .tokenChecked)
        #expect(model.status.botName == "Waggle Test Bot")
        #expect(model.token == "")

        await model.startPairing()
        #expect(model.status.state == .waitingForStart)
        #expect(model.status.code == "ABC234")

        await model.sendTest()
        #expect(model.note == "Test sent. Look at your phone.")

        await model.disconnect()
        #expect(model.status.state == .off)
        await client.stop()
    }

    @Test func aRefusedTokenShowsTheDaemonsWordsAndKeepsTheField() async throws {
        let log = Log()
        let (client, server) = try await connectedClient(log: log)
        defer { server.stop() }
        let model = PhoneSettingsModel(client: client)
        model.token = "bad"
        await model.checkToken()
        #expect(model.problem == "Telegram did not accept that token. Check it and try again.")
        #expect(model.token == "bad")
        #expect(model.status.state == .off)
        await client.stop()
    }

    @Test func aBlankTokenSendsNothing() async throws {
        let log = Log()
        let (client, server) = try await connectedClient(log: log)
        defer { server.stop() }
        let model = PhoneSettingsModel(client: client)
        model.token = "   "
        await model.checkToken()
        #expect(!log.calls.contains("connectors.telegram.check_token"))
        await client.stop()
    }

    // MARK: - Slack (HAIL-145)

    @Test func slackConnectFlowWalksTheStates() async throws {
        let log = Log()
        let (client, server) = try await connectedClient(log: log)
        defer { server.stop() }
        let model = PhoneSettingsModel(client: client)
        await model.refresh()
        #expect(model.slack.state == .off)

        model.slackAppToken = " xapp-1-abc "
        model.slackBotToken = "xoxb-abc"
        await model.slackCheckTokens()
        #expect(model.slack.state == .tokenChecked)
        #expect(model.slack.workspace == "Acme Inc")
        #expect(model.slackAppToken == "" && model.slackBotToken == "")
        #expect(log.calls.contains("slack:xapp-1-abc|xoxb-abc"))

        await model.slackStartPairing()
        #expect(model.slack.state == .waitingForStart)
        #expect(model.slack.code == "XYZ789")

        await model.slackSendTest()
        #expect(model.slackNote == "Test sent. Look at your Slack DM.")

        await model.slackDisconnect()
        #expect(model.slack.state == .off)
        await client.stop()
    }

    @Test func aRefusedSlackTokenShowsTheDaemonsWordsAndKeepsTheFields() async throws {
        let log = Log()
        let (client, server) = try await connectedClient(log: log)
        defer { server.stop() }
        let model = PhoneSettingsModel(client: client)
        model.slackAppToken = "xapp-1-abc"
        model.slackBotToken = "xoxb-bad"
        await model.slackCheckTokens()
        #expect(model.slackProblem == "Slack did not accept that token. Check it and try again.")
        #expect(model.slackBotToken == "xoxb-bad")
        #expect(model.slack.state == .off)
        await client.stop()
    }

    @Test func slackNeedsBothTokensBeforeItSendsAnything() async throws {
        let log = Log()
        let (client, server) = try await connectedClient(log: log)
        defer { server.stop() }
        let model = PhoneSettingsModel(client: client)
        model.slackAppToken = "xapp-1-abc"
        await model.slackCheckTokens()
        #expect(!log.calls.contains { $0.hasPrefix("slack:") })
        await client.stop()
    }

    @Test func aDaemonWithoutSlackReportsItOff() throws {
        let json = #"{"telegram":\#(Self.status("off"))}"#
        let result = try JSONDecoder().decode(ConnectorsStatusResult.self, from: Data(json.utf8))
        #expect(result.slack.state == .off)
    }

    @Test func aSlackAnswerReadsAnsweredFromSlack() {
        #expect(answered(source: .slack, choice: "b").answeredSummaryLine == "Answered from Slack → Trust")
    }

    @Test func theDataPageNamesBothChatServices() {
        #expect(SettingsPage.data.subtitle.contains("Telegram or Slack"))
        #expect(!SettingsPage.data.subtitle.contains("—"))
    }

    // MARK: - reply source

    private func answered(source: ReplySource?, choice: String? = "a", message: String? = nil) -> Case {
        Case(
            id: "c_1", taskId: "t_1", kind: .question, title: "Title", need: "Need", why: "Why",
            recommendation: "a", recommendationWhy: "Because",
            options: [Option(id: "a", label: "Approval rules"), Option(id: "b", label: "Trust")],
            status: .waitingOnAgent, hasArtifact: false, latestReplyId: "r1",
            latestReplyChoice: choice, latestReplyMessage: message, latestReplySource: source,
            createdAt: "2026-10-03T10:00:00.000Z", updatedAt: "2026-10-03T10:00:00.000Z"
        )
    }

    @Test func aTelegramAnswerReadsAnsweredFromTelegram() {
        #expect(answered(source: .telegram, choice: "b").answeredSummaryLine == "Answered from Telegram → Trust")
        #expect(answered(source: .telegram, choice: "a").answeredSummaryLine == "Answered from Telegram → accepted: Approval rules")
    }

    @Test func aMacOrUnknownSourceKeepsTheYouLine() {
        #expect(answered(source: .mac, choice: "b").answeredSummaryLine == "you → Trust")
        #expect(answered(source: nil, choice: "b").answeredSummaryLine == "you → Trust")
    }

    @Test func caseAndReplyDecodeTheirSourceAndTolerateAnUnknownOne() throws {
        let reply = #"{"id":"r","case_id":"c","idempotency_key":"k","comments":[],"captures":[],"intent":"decision","source":"telegram","state":"queued","created_at":"2026-10-03T10:00:00.000Z"}"#
        #expect(try JSONDecoder().decode(Reply.self, from: Data(reply.utf8)).source == .telegram)
        let future = reply.replacingOccurrences(of: "telegram", with: "carrier-pigeon")
        #expect(try JSONDecoder().decode(Reply.self, from: Data(future.utf8)).source == .mac)
        let old = reply.replacingOccurrences(of: #""source":"telegram","#, with: "")
        #expect(try JSONDecoder().decode(Reply.self, from: Data(old.utf8)).source == .mac)
    }
}
