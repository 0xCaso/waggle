import AppKit
import SwiftUI

/// Holds the Phone page's Telegram connection (HAIL-144). The daemon owns everything: the token
/// goes to the Keychain there, the chat id into its settings. The page only sends the steps and
/// shows the status the daemon reports. While the page is open it asks for the status every
/// couple of seconds, so a `/start <code>` sent on the phone shows up as "Connected".
@MainActor
final class PhoneSettingsModel: ObservableObject {
    @Published private(set) var status: TelegramStatus = .off
    @Published private(set) var isBusy = false
    /// The last step's problem, in plain words. Cleared by the next step.
    @Published private(set) var problem: String?
    /// "Test sent. Look at your phone." after "Send a test".
    @Published private(set) var note: String?
    @Published var token = ""

    // Slack (HAIL-145). The same daemon status call carries it, so one poll serves both sections.
    @Published private(set) var slack: SlackStatus = .off
    @Published private(set) var slackProblem: String?
    @Published private(set) var slackNote: String?
    @Published var slackAppToken = ""
    @Published var slackBotToken = ""

    // The guided flow (HAIL-148). The daemon's state decides the step once a bot or a token pair is
    // saved. Before that the operator moves with Next and Back, and the override remembers where.
    @Published var telegramStepOverride: Int?
    @Published var slackStepOverride: Int?
    private var lastLookedUpBot = ""

    private let client: KnockClient
    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?
    /// Opens a link. Only a click calls it. Tests pass their own.
    let openURL: (URL) -> Void

    init(
        client: KnockClient,
        pollInterval: Duration = .seconds(2),
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.client = client
        self.pollInterval = pollInterval
        self.openURL = openURL
    }

    func start() async {
        guard pollTask == nil else { return }
        await refresh()
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                await self?.refresh()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        guard !isBusy, let result = try? await client.connectorsStatus() else { return }
        status = result.telegram
        slack = result.slack
    }

    func checkToken() async {
        let pasted = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pasted.isEmpty else { return }
        await run { [client] in try await client.telegramCheckToken(pasted) } onSuccess: { [weak self] in self?.token = "" }
    }

    func startPairing() async {
        await run { [client] in try await client.telegramStartPairing() }
    }

    func disconnect() async {
        await run { [client] in try await client.telegramDisconnect() }
    }

    func sendTest() async {
        isBusy = true
        problem = nil
        note = nil
        defer { isBusy = false }
        do {
            try await client.telegramSendTest()
            note = "Test sent. Look at your phone."
        } catch {
            problem = Self.words(for: error)
        }
    }

    func slackCheckTokens() async {
        let app = slackAppToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let bot = slackBotToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !app.isEmpty, !bot.isEmpty else { return }
        await runSlack({ [client] in try await client.slackCheckTokens(app: app, bot: bot) }, onSuccess: { [weak self] in
            self?.slackAppToken = ""
            self?.slackBotToken = ""
        })
    }

    func slackStartPairing() async {
        await runSlack { [client] in try await client.slackStartPairing() }
    }

    func slackDisconnect() async {
        await runSlack { [client] in try await client.slackDisconnect() }
    }

    func slackSendTest() async {
        isBusy = true
        slackProblem = nil
        slackNote = nil
        defer { isBusy = false }
        do {
            try await client.slackSendTest()
            slackNote = "Test sent. Look at your Slack DM."
        } catch {
            slackProblem = Self.words(for: error)
        }
    }

    private func runSlack(_ step: () async throws -> SlackStatus, onSuccess: (() -> Void)? = nil) async {
        isBusy = true
        slackProblem = nil
        slackNote = nil
        defer { isBusy = false }
        do {
            slack = try await step()
            onSuccess?()
        } catch {
            slackProblem = Self.words(for: error)
        }
    }

    private func run(_ step: () async throws -> TelegramStatus, onSuccess: (() -> Void)? = nil) async {
        isBusy = true
        problem = nil
        note = nil
        defer { isBusy = false }
        do {
            status = try await step()
            onSuccess?()
        } catch {
            problem = Self.words(for: error)
        }
    }

    // MARK: Guided flow (HAIL-148)

    static let telegramStepCount = 4
    static let slackStepCount = 6

    /// 1 BotFather, 2 paste the token, 3 open your bot, 4 connected.
    var telegramStep: Int {
        switch status.state {
        case .connected: return 4
        case .tokenChecked, .waitingForStart: return 3
        case .off: return min(max(telegramStepOverride ?? 1, 1), 2)
        }
    }

    /// 1 create the app, 2 install and bot token, 3 app-level token, 4 check, 5 DM the code, 6 connected.
    var slackStep: Int {
        switch slack.state {
        case .connected: return 6
        case .tokenChecked, .waitingForStart: return 5
        case .off:
            let floor = slack.appId != nil ? 3 : 1
            return min(max(slackStepOverride ?? floor, 1), 4)
        }
    }

    func goTelegram(_ step: Int) { telegramStepOverride = step }
    func goSlack(_ step: Int) { slackStepOverride = step }

    func open(_ url: URL?) {
        if let url { openURL(url) }
    }

    /// Live shape problem for the Telegram field. Nil while the field is empty or fine.
    var telegramTokenProblem: String? { TokenShape.telegramProblem(token) }
    var slackAppProblem: String? { TokenShape.slackAppProblem(slackAppToken) }
    var slackBotProblem: String? { TokenShape.slackBotProblem(slackBotToken) }
    var slackFieldsSwapped: Bool { TokenShape.slackAreSwapped(app: slackAppToken, bot: slackBotToken) }

    func swapSlackTokens() {
        let app = slackAppToken
        slackAppToken = slackBotToken
        slackBotToken = app
    }

    /// Check the pasted token, then make the code at once so step 3 can open the bot. A bad shape is
    /// refused here without a call.
    func checkTokenGuided() async {
        guard telegramTokenProblem == nil else { return }
        await checkToken()
        if status.state == .tokenChecked, problem == nil { await startPairing() }
    }

    /// Check both Slack tokens, then make the code at once. A pair in the wrong boxes is swapped first.
    /// Any other wrong paste is refused here without a call, and the field shows why.
    func checkSlackGuided() async {
        if slackFieldsSwapped { swapSlackTokens() }
        guard slackAppProblem == nil, slackBotProblem == nil else { return }
        await slackCheckTokens()
        if slack.state == .tokenChecked, slackProblem == nil { await slackStartPairing() }
    }

    /// Step 2 has the bot token. Ask the daemon which app it belongs to, so step 3 can link the app's
    /// own page. Quiet on failure: the link then goes to the list of apps.
    func lookUpSlackApp() async {
        let bot = slackBotToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TokenShape.isSlackBot(bot), bot != lastLookedUpBot else { return }
        lastLookedUpBot = bot
        if let result = try? await client.slackLookUpApp(bot: bot) { slack = result }
    }

    /// Back to step 1 of Telegram: forget the bot in the daemon and clear what was typed.
    func startOverTelegram() async {
        await disconnect()
        token = ""
        telegramStepOverride = nil
    }

    func startOverSlack() async {
        await slackDisconnect()
        slackAppToken = ""
        slackBotToken = ""
        lastLookedUpBot = ""
        slackStepOverride = nil
    }

    /// Evidence only (HAIL-148): `KNOCK_EVIDENCE_PHONE=<telegram|slack>|<step>|<field 1>|<field 2>|check`
    /// opens a guide step with the boxes filled in, and "check" presses Check. Fields: the token for
    /// Telegram; the bot token then the app-level token for Slack. A capture cannot type or click.
    func applyEvidence(_ environment: [String: String]) async {
        guard let raw = environment["KNOCK_EVIDENCE_PHONE"], !raw.isEmpty else { return }
        let parts = raw.components(separatedBy: "|")
        guard parts.count >= 2, let step = Int(parts[1]) else { return }
        let fields = parts.dropFirst(2).filter { $0 != "check" }
        switch parts[0] {
        case "telegram":
            if let t = fields.first { token = t }
            telegramStepOverride = step
            if parts.contains("check") { await checkTokenGuided() }
        case "slack":
            if fields.count > 0 { slackBotToken = fields[0] }
            if fields.count > 1 { slackAppToken = fields[1] }
            slackStepOverride = step
            await lookUpSlackApp()
            if parts.contains("check") { await checkSlackGuided() }
        default:
            break
        }
    }

    /// The daemon's own words for a refused step, else a plain fallback.
    static func words(for error: Error) -> String {
        if let rpc = error as? JSONRPCErrorPayload, rpc.code == -32010 { return rpc.message }
        return "Waggle could not do that. Try again in a moment."
    }
}

/// The Phone page (HAIL-144, Slack added in HAIL-145): connect Telegram or Slack so a new ask reaches your phone and a tap or a text
/// reply goes back to the same agent. Off until you connect it. Four states: empty, token checked,
/// waiting for /start, connected.
struct PhoneSettingsView: View {
    @StateObject private var model: PhoneSettingsModel

    init(client: KnockClient) {
        _model = StateObject(wrappedValue: PhoneSettingsModel(client: client))
    }

    var body: some View {
        SettingsPageChrome(title: SettingsPage.phone.title, subtitle: SettingsPage.phone.subtitle) {
            VStack(alignment: .leading, spacing: 8) {
                if Self.shows("telegram") { TelegramSection(model: model) }
                if Self.shows("slack") {
                    SlackSection(model: model)
                        .padding(.top, Self.shows("telegram") ? 14 : 0)
                }
            }
        }
        .task {
            await model.start()
            await model.applyEvidence(ProcessInfo.processInfo.environment)
        }
        .onDisappear { model.stop() }
    }

    /// Evidence only (HAIL-145, HAIL-148): `KNOCK_EVIDENCE_PHONE_ONLY=telegram|slack` shows one section so a
    /// window capture holds a whole guide without a scroll. The old `KNOCK_EVIDENCE_PHONE_HIDE_TELEGRAM=1` still works.
    private static func shows(_ connector: String) -> Bool {
        let env = ProcessInfo.processInfo.environment
        if let only = env["KNOCK_EVIDENCE_PHONE_ONLY"], !only.isEmpty { return only == connector }
        return !(connector == "telegram" && env["KNOCK_EVIDENCE_PHONE_HIDE_TELEGRAM"] == "1")
    }
}
