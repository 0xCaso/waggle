import Testing
import Foundation
@testable import Knock

/// HAIL-148: links, token shapes and the step logic of the guided connect flow.
@MainActor
struct ConnectorGuideTests {
    // MARK: Links

    @Test func theManifestURLKeepsEveryCharacterSafeAndRoundTrips() throws {
        let manifest = "{\n  \"display_information\": { \"name\": \"Waggle & co\" },\n  \"x\": \"a#b?c=d+e%f\"\n}"
        let url = try #require(ConnectorLinks.slackCreateApp(manifest: manifest))
        let text = url.absoluteString
        #expect(text.hasPrefix("https://api.slack.com/apps?new_app=1&manifest_json="))
        let value = String(text.dropFirst("https://api.slack.com/apps?new_app=1&manifest_json=".count))
        for bad in ["{", "}", "\"", " ", "\n", "&", "#", "?", "=", "+", ":"] {
            #expect(!value.contains(bad), "raw \(bad.debugDescription) left in the value")
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items?.first(where: { $0.name == "new_app" })?.value == "1")
        #expect(items?.first(where: { $0.name == "manifest_json" })?.value == manifest)
        #expect(ConnectorLinks.slackCreateApp(manifest: "") == nil)
    }

    @Test func telegramDeepLinkCarriesTheCode() {
        #expect(ConnectorLinks.telegramBot(username: "knock_test_bot", code: "ABC234")?.absoluteString
            == "https://t.me/knock_test_bot?start=ABC234")
        #expect(ConnectorLinks.telegramBot(username: nil, code: "ABC234") == nil)
        #expect(ConnectorLinks.telegramBot(username: "knock_test_bot", code: nil) == nil)
        // Nothing that could change the link is let through.
        #expect(ConnectorLinks.telegramBot(username: "bot/../x", code: "ABC234") == nil)
        #expect(ConnectorLinks.telegramBot(username: "knock_test_bot", code: "A B&c=1") == nil)
        #expect(ConnectorLinks.botFather.absoluteString == "https://t.me/BotFather")
    }

    @Test func slackLinksUseTheIdsAndFallBackWhenTheyAreUnknown() {
        #expect(ConnectorLinks.slackAppPage(appId: "A0KNOCK").absoluteString == "https://api.slack.com/apps/A0KNOCK/general")
        #expect(ConnectorLinks.slackAppPage(appId: nil) == ConnectorLinks.slackApps)
        #expect(ConnectorLinks.slackAppPage(appId: "../evil") == ConnectorLinks.slackApps)
        #expect(ConnectorLinks.slackDM(teamId: "T0ACME", botUserId: "UBOT")?.absoluteString == "slack://user?team=T0ACME&id=UBOT")
        #expect(ConnectorLinks.slackDM(teamId: nil, botUserId: "UBOT") == nil)
        #expect(ConnectorLinks.slackDM(teamId: "T0ACME&x=1", botUserId: "UBOT") == nil)
    }

    @Test func aDestinationReadsPlainlyAndSkipsTheManifest() throws {
        #expect(ConnectorLinks.destination(ConnectorLinks.botFather) == "t.me/BotFather")
        let tg = try #require(ConnectorLinks.telegramBot(username: "knock_test_bot", code: "ABC234"))
        #expect(ConnectorLinks.destination(tg) == "t.me/knock_test_bot?start=ABC234")
        let create = try #require(ConnectorLinks.slackCreateApp(manifest: "{}"))
        #expect(ConnectorLinks.destination(create) == "api.slack.com/apps")
    }

    // MARK: Token shapes

    @Test func aTokenInTheWrongSlackBoxIsNamed() {
        #expect(TokenShape.slackAppProblem("xapp-1-A") == nil)
        #expect(TokenShape.slackAppProblem("")  == nil)
        #expect(TokenShape.slackAppProblem("xoxb-1-A")?.contains("bot token") == true)
        #expect(TokenShape.slackAppProblem("nope")?.contains("starts with xapp-") == true)
        #expect(TokenShape.slackBotProblem("xoxb-1-A") == nil)
        #expect(TokenShape.slackBotProblem("xapp-1-A")?.contains("app-level token") == true)
        #expect(TokenShape.slackBotProblem("nope")?.contains("starts with xoxb-") == true)
        #expect(TokenShape.slackAreSwapped(app: " xoxb-1 ", bot: "xapp-1"))
        #expect(!TokenShape.slackAreSwapped(app: "xoxb-1", bot: "xoxb-2"))
        #expect(!TokenShape.slackAreSwapped(app: "xapp-1", bot: "xoxb-1"))
    }

    @Test func telegramTokenShape() {
        #expect(TokenShape.telegramProblem("123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw") == nil)
        #expect(TokenShape.telegramProblem("  ") == nil)
        #expect(TokenShape.telegramProblem("hello")?.contains("does not look like a bot token") == true)
        #expect(TokenShape.telegramProblem("xoxb-1-2")?.contains("Slack token") == true)
    }

    @Test func noCopyHasAnEmDash() {
        let words = [
            TokenShape.telegramProblem("x"), TokenShape.slackAppProblem("x"), TokenShape.slackBotProblem("x"),
            TokenShape.slackAppProblem("xoxb-1"), TokenShape.slackBotProblem("xapp-1"),
        ].compactMap { $0 }
        for w in words { #expect(!w.contains("—")) }
    }

    // MARK: Model

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
        func add(_ value: String) { lock.lock(); _calls.append(value); lock.unlock() }
    }

    private nonisolated static func slack(_ state: String, app: Bool = true, code: String? = nil) -> String {
        let named = state == "off" ? "null" : #""Acme Inc""#
        let ids = app ? #","app_id":"A0KNOCK","team_id":"T0ACME","bot_user_id":"UBOT""# : ""
        return #"{"state":"\#(state)","workspace":\#(named),"bot_name":"knock","user_label":null,"code":\#(code.map { "\"\($0)\"" } ?? "null"),"manifest":"{}","error":null\#(ids)}"#
    }

    private func client(log: Log) async throws -> (KnockClient, FakeKnockServer) {
        let path = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: path)
        server.onRequest = { method, id, line in
            guard let id else { return nil }
            log.add(method)
            switch method {
            case "connectors.slack.look_up_app":
                return jsonRPCOK(id: id, result: Self.slack("off"))
            case "connectors.slack.check_tokens":
                let params = (try? JSONSerialization.jsonObject(with: line) as? [String: Any])?["params"] as? [String: Any]
                log.add("tokens:\(params?["app_token"] as? String ?? "")|\(params?["bot_token"] as? String ?? "")")
                return jsonRPCOK(id: id, result: Self.slack("token_checked"))
            case "connectors.slack.start_pairing":
                return jsonRPCOK(id: id, result: Self.slack("waiting_for_start", code: "XYZ789"))
            case "connectors.telegram.check_token":
                return jsonRPCOK(id: id, result: #"{"state":"token_checked","bot_name":"Knock","bot_username":"knock_test_bot","chat_label":null,"code":null,"error":null}"#)
            case "connectors.telegram.start_pairing":
                return jsonRPCOK(id: id, result: #"{"state":"waiting_for_start","bot_name":"Knock","bot_username":"knock_test_bot","chat_label":null,"code":"ABC234","error":null}"#)
            default:
                return nil
            }
        }
        try server.start()
        let client = KnockClient(socketPath: path, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        return (client, server)
    }

    @Test func slackStepsFollowTheDaemonAndTheOverride() async throws {
        let log = Log()
        let (c, server) = try await client(log: log)
        defer { server.stop() }
        let model = PhoneSettingsModel(client: c)
        #expect(model.slackStep == 1)
        model.goSlack(2)
        #expect(model.slackStep == 2)
        model.goSlack(9)
        #expect(model.slackStep == 3)
        model.slackBotToken = "xoxb-1-A"
        await model.lookUpSlackApp()
        #expect(model.slack.appId == "A0KNOCK")
        await model.lookUpSlackApp()
        #expect(log.calls.filter { $0 == "connectors.slack.look_up_app" }.count == 1)
        await c.stop()
    }

    @Test func slackKnownAppJumpsToTheAppTokenStep() async throws {
        let (c, server) = try await client(log: Log())
        defer { server.stop() }
        let model = PhoneSettingsModel(client: c)
        model.slackBotToken = "xoxb-1-A"
        await model.lookUpSlackApp()
        #expect(model.slackStep == 2)
        await c.stop()
    }

    @Test func swappedSlackTokensAreFixedThenCheckedAndTheCodeIsMade() async throws {
        let log = Log()
        let (c, server) = try await client(log: log)
        defer { server.stop() }
        let model = PhoneSettingsModel(client: c)
        model.slackAppToken = "xoxb-1-BOT"
        model.slackBotToken = "xapp-1-APP"
        #expect(model.slackFieldsSwapped)
        await model.checkSlackGuided()
        #expect(log.calls.contains("tokens:xapp-1-APP|xoxb-1-BOT"))
        #expect(model.slack.state == .waitingForStart)
        #expect(model.slack.code == "XYZ789")
        #expect(model.slackStep == 4)
        await c.stop()
    }

    @Test func aWrongBoxIsRefusedWithoutACall() async throws {
        let log = Log()
        let (c, server) = try await client(log: log)
        defer { server.stop() }
        let model = PhoneSettingsModel(client: c)
        model.slackAppToken = "xoxb-1-BOT"
        model.slackBotToken = "xoxb-2-BOT"
        await model.checkSlackGuided()
        #expect(model.slackAppProblem?.contains("bot token") == true)
        #expect(!log.calls.contains("connectors.slack.check_tokens"))
        await c.stop()
    }

    @Test func telegramCheckMakesTheCodeAndOpensTheDeepLink() async throws {
        let log = Log()
        let (c, server) = try await client(log: log)
        defer { server.stop() }
        var opened: [URL] = []
        let model = PhoneSettingsModel(client: c, openURL: { opened.append($0) })
        #expect(model.telegramStep == 1)
        model.token = "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw"
        await model.checkTokenGuided()
        #expect(model.status.state == .waitingForStart)
        #expect(model.telegramStep == 2)
        model.open(ConnectorLinks.telegramBot(username: model.status.botUsername, code: model.status.code))
        #expect(opened.map(\.absoluteString) == ["https://t.me/knock_test_bot?start=ABC234"])
        await c.stop()
    }

    @Test func theGuidesHaveNoGateClicks() {
        // Telegram: BotFather and the token box share step 1. Slack: the app and the bot token share step 1.
        #expect(PhoneSettingsModel.telegramStepCount == 3)
        #expect(PhoneSettingsModel.slackStepCount == 5)
    }

    @Test func telegramNeedsNoNextClickBetweenBotFatherAndTheToken() async throws {
        let (c, server) = try await client(log: Log())
        defer { server.stop() }
        let model = PhoneSettingsModel(client: c)
        // The token box is on step 1, so a pasted token is checked with no step change first.
        #expect(model.telegramStep == 1)
        model.token = "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw"
        #expect(model.telegramTokenProblem == nil)
        await model.checkTokenGuided()
        #expect(model.telegramStep == 2)
        await c.stop()
    }

    @Test func slackKeepsTheBotTokenOnStepOneAndTheLaterStepsStillMove() async throws {
        let (c, server) = try await client(log: Log())
        defer { server.stop() }
        let model = PhoneSettingsModel(client: c)
        #expect(model.slackStep == 1)
        model.slackBotToken = "xoxb-1-A"
        await model.lookUpSlackApp()
        #expect(model.slackStep == 2)
        model.slackAppToken = "xapp-1-APP"
        model.goSlack(3)
        #expect(model.slackStep == 3)
        await model.checkSlackGuided()
        #expect(model.slackStep == 4)
        await c.stop()
    }

    @Test func aBadTelegramShapeSendsNothing() async throws {
        let log = Log()
        let (c, server) = try await client(log: log)
        defer { server.stop() }
        let model = PhoneSettingsModel(client: c)
        model.token = "hello"
        await model.checkTokenGuided()
        #expect(model.telegramTokenProblem != nil)
        #expect(!log.calls.contains("connectors.telegram.check_token"))
        await c.stop()
    }

    @Test func errorsMapToPlainWords() {
        let rpc = JSONRPCErrorPayload(code: -32010, message: "Could not reach Telegram. Check your connection.")
        #expect(PhoneSettingsModel.words(for: rpc) == "Could not reach Telegram. Check your connection.")
        #expect(PhoneSettingsModel.words(for: URLError(.notConnectedToInternet)) == "Waggle could not do that. Try again in a moment.")
    }

    @Test func aDaemonThatDoesNotKnowTheIdsStillDecodes() throws {
        let old = #"{"state":"off","workspace":null,"bot_name":null,"user_label":null,"code":null,"manifest":"{}","error":null}"#
        let status = try JSONDecoder().decode(SlackStatus.self, from: Data(old.utf8))
        #expect(status.appId == nil && status.teamId == nil && status.botUserId == nil)
    }
}
