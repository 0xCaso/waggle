import SwiftUI

/// The Telegram section of the Phone page (HAIL-144), as a guided flow (HAIL-148): open BotFather,
/// paste the token, open the bot with the code in the link, connected. The daemon owns everything.
struct TelegramSection: View {
    @ObservedObject var model: PhoneSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionLabel("TELEGRAM")
            SettingsCard {
                GuideProgress(
                    step: model.telegramStep,
                    count: PhoneSettingsModel.telegramStepCount,
                    startOver: { Task { await model.startOverTelegram() } },
                    busy: model.isBusy
                )
                let current = model.telegramStep
                GuideStep(number: 1, title: "Make a bot in Telegram", current: current) { openBotFather }
                GuideStep(number: 2, title: "Paste the bot token", current: current) { pasteToken }
                GuideStep(number: 3, title: "Open your bot", current: current) { openBot }
                GuideStep(number: 4, title: connectedTitle, current: current) { connected }
            }
            if let problem = model.status.error, model.problem == nil, model.telegramStep != 2 {
                Text(problem)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Waggle talks to Telegram only after you connect it. Your bot token stays in the Keychain on this Mac.")
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(Theme.Colors.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectedTitle: String {
        model.telegramStep == 4 ? "Connected to \(model.status.chatLabel ?? "your chat")" : "Connected"
    }

    private var openBotFather: some View {
        VStack(alignment: .leading, spacing: 10) {
            GuideText("BotFather is Telegram's own bot for making bots. Send it /newbot, pick a name for your bot, then copy the token it gives you.")
            GuideLinkButton(title: "Open BotFather", url: ConnectorLinks.botFather, open: model.open)
            GuideNav(next: { model.goTelegram(2) }, nextTitle: "I have my token")
        }
    }

    private var pasteToken: some View {
        VStack(alignment: .leading, spacing: 10) {
            GuideText("The token looks like 123456789:ABC... Waggle checks it with Telegram.")
            HStack(alignment: .top, spacing: 8) {
                GuideTokenField(
                    placeholder: "Bot token",
                    text: $model.token,
                    problem: model.telegramTokenProblem ?? model.problem,
                    onSubmit: { Task { await model.checkTokenGuided() } }
                )
                SettingsPrimaryButton(title: "Check token") { Task { await model.checkTokenGuided() } }
                    .disabled(model.isBusy || model.token.trimmingCharacters(in: .whitespaces).isEmpty
                        || model.telegramTokenProblem != nil)
            }
            GuideNav(back: { model.goTelegram(1) })
        }
    }

    private var openBot: some View {
        let bot = model.status.botUsername.map { "@\($0)" } ?? "your bot"
        let code = model.status.code
        return VStack(alignment: .leading, spacing: 10) {
            if let code {
                GuideText("\(model.status.botName ?? "Your bot") is ready. Tap the button, then tap Start in Telegram. That sends the code for you.")
                GuideLinkButton(
                    title: "Open your bot",
                    url: ConnectorLinks.telegramBot(username: model.status.botUsername, code: code),
                    open: model.open
                )
                GuideText("If the button does not work, send this message to \(bot) yourself.")
                GuideCodeRow(text: "/start \(code)")
            } else {
                GuideText("Waggle makes a one-time code, then you open \(bot) and send it.")
                SettingsPrimaryButton(title: "Get my code") { Task { await model.startPairing() } }
                    .disabled(model.isBusy)
            }
            if let problem = model.problem {
                Text(problem)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.accent)
            }
        }
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 10) {
            GuideText("New decisions arrive in this chat. Tap a button, or reply to the message to answer in your own words.")
            HStack(spacing: 8) {
                SettingsSecondaryButton(title: "Send a test") { Task { await model.sendTest() } }
                SettingsSecondaryButton(title: "Disconnect") { Task { await model.startOverTelegram() } }
            }
            .fixedSize()
            .disabled(model.isBusy)
            if let note = model.note {
                Text(note)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.ok)
            }
            if let problem = model.problem {
                Text(problem)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.accent)
            }
        }
    }
}
