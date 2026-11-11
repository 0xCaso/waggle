import AppKit
import SwiftUI

/// The Slack section of the Phone page (HAIL-145), as a guided flow (HAIL-148): create the app from
/// the manifest, install it and copy the bot token, make the app-level token, check both, DM the
/// code, connected. Slack only issues the app-level token on the app's own page, so that step says
/// exactly where to click. The daemon owns everything; this sends the steps and shows its status.
struct SlackSection: View {
    @ObservedObject var model: PhoneSettingsModel
    @State private var manifestCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionLabel("SLACK")
            SettingsCard {
                GuideProgress(
                    step: model.slackStep,
                    count: PhoneSettingsModel.slackStepCount,
                    startOver: { Task { await model.startOverSlack() } },
                    busy: model.isBusy
                )
                let current = model.slackStep
                GuideStep(number: 1, title: "Create the Slack app and copy the bot token", current: current) { createApp }
                GuideStep(number: 2, title: "Make the app-level token", current: current) { appToken }
                GuideStep(number: 3, title: "Check both tokens", current: current) { check }
                GuideStep(number: 4, title: "Send the code to the bot", current: current) { sendCode }
                GuideStep(number: 5, title: connectedTitle, current: current) { connected }
            }
            if let error = model.slack.error, model.slackProblem == nil, model.slackStep != 3 {
                Text(error)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Waggle talks to Slack only after you connect it. Both tokens stay in the Keychain on this Mac.")
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(Theme.Colors.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectedTitle: String {
        model.slackStep == 5 ? "Connected as \(model.slack.userLabel ?? "you")" : "Connected"
    }

    // MARK: Steps

    private var createApp: some View {
        VStack(alignment: .leading, spacing: 10) {
            GuideText("The button opens Slack with the app already filled in. Pick your workspace, click Next, then click Create.")
            HStack(alignment: .top, spacing: 12) {
                GuideLinkButton(
                    title: "Create the Slack app",
                    url: ConnectorLinks.slackCreateApp(manifest: model.slack.manifest),
                    open: model.open
                )
                SettingsSecondaryButton(icon: "doc.on.doc", title: manifestCopied ? "Copied" : "Copy manifest") { copyManifest() }
                    .help("Copies the app manifest, to paste into Slack's \"From a manifest\" box")
            }
            GuideText("If the page asks for a manifest, choose the JSON tab and paste what Copy manifest gave you.")
            GuideText("On the app page, click Install App in the left menu, then Install to Workspace, then Allow. Copy the Bot User OAuth Token. It starts with xoxb-.")
            GuideTokenField(
                placeholder: "Bot token (xoxb-...)",
                text: $model.slackBotToken,
                problem: model.slackBotProblem,
                onSubmit: { Task { await model.lookUpSlackApp() } }
            )
            .onChange(of: model.slackBotToken) { _ in Task { await model.lookUpSlackApp() } }
            wrongBoxFix
            GuideNav(
                next: { model.goSlack(2) },
                nextEnabled: TokenShape.isSlackBot(model.slackBotToken.trimmingCharacters(in: .whitespaces))
            )
        }
    }

    private var appToken: some View {
        VStack(alignment: .leading, spacing: 10) {
            GuideText("Slack only makes this token on the app's Basic Information page, so it is not in the same place as the bot token.")
            VStack(alignment: .leading, spacing: 4) {
                GuideText("1. Open Basic Information and scroll to App-Level Tokens.")
                GuideText("2. Click Generate Token and Scopes. Name it Waggle.")
                GuideText("3. Click Add Scope and pick connections:write. Click Generate.")
                GuideText("4. Copy the token. It starts with xapp-.")
            }
            GuideLinkButton(
                title: "Open Basic Information",
                url: ConnectorLinks.slackAppPage(appId: model.slack.appId),
                primary: false,
                open: model.open
            )
            GuideTokenField(
                placeholder: "App-level token (xapp-...)",
                text: $model.slackAppToken,
                problem: model.slackAppProblem
            )
            wrongBoxFix
            GuideNav(
                back: { model.goSlack(1) },
                next: { model.goSlack(3) },
                nextEnabled: TokenShape.isSlackApp(model.slackAppToken.trimmingCharacters(in: .whitespaces))
            )
        }
    }

    private var check: some View {
        VStack(alignment: .leading, spacing: 10) {
            GuideText("Waggle asks Slack about both tokens and opens a short test connection. Nothing is saved until both pass.")
            tokenSummary("Bot token", model.slackBotToken)
            tokenSummary("App-level token", model.slackAppToken)
            wrongBoxFix
            if let problem = model.slackProblem {
                Text(problem)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                SettingsPrimaryButton(title: "Check tokens") { Task { await model.checkSlackGuided() } }
                    .disabled(model.isBusy || !tokensReady)
                    .opacity(tokensReady ? 1 : 0.5)
                SettingsSecondaryButton(title: "Back") { model.goSlack(2) }
            }
        }
    }

    private var tokensReady: Bool {
        !model.slackAppToken.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.slackBotToken.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func tokenSummary(_ label: String, _ value: String) -> some View {
        let pasted = !value.trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(spacing: 6) {
            Image(systemName: pasted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11))
                .foregroundColor(pasted ? Theme.Colors.ok : Theme.Colors.ink3)
            Text(pasted ? "\(label) pasted" : "\(label) missing. Go back and paste it.")
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(pasted ? Theme.Colors.ink : Theme.Colors.ink3)
        }
    }

    /// Both tokens sit in the other's box: say so and offer the fix. Check tokens also fixes it.
    @ViewBuilder private var wrongBoxFix: some View {
        if model.slackFieldsSwapped {
            HStack(spacing: 8) {
                Text("These two look swapped.")
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.accent)
                SettingsSecondaryButton(icon: "arrow.left.arrow.right", title: "Swap them") { model.swapSlackTokens() }
            }
        }
    }

    private var sendCode: some View {
        let code = model.slack.code
        let bot = model.slack.botName.map { "@\($0)" } ?? "the bot"
        let dm = ConnectorLinks.slackDM(teamId: model.slack.teamId, botUserId: model.slack.botUserId)
        return VStack(alignment: .leading, spacing: 10) {
            if let code {
                GuideText("Both tokens passed. Open a direct message with \(bot) in Slack and send it this code. Waggle links your account when it sees it.")
                if let dm {
                    GuideLinkButton(title: "Open Slack", url: dm, open: model.open)
                    GuideText("If the button does not open the chat, find \(bot) under Apps in Slack and send the code yourself.")
                } else {
                    GuideText("In Slack, find \(bot) under Apps and open a direct message with it.")
                }
                GuideCodeRow(text: code)
            } else {
                GuideText("Waggle makes a one-time code, then you send it to \(bot) in a direct message.")
                SettingsPrimaryButton(title: "Get my code") { Task { await model.slackStartPairing() } }
                    .disabled(model.isBusy)
            }
            if let problem = model.slackProblem {
                Text(problem)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.accent)
            }
        }
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 10) {
            GuideText("New decisions arrive in your direct messages with the bot. Press a button, or reply in the thread to answer in your own words.")
            HStack(spacing: 8) {
                SettingsSecondaryButton(title: "Send a test") { Task { await model.slackSendTest() } }
                SettingsSecondaryButton(title: "Disconnect") { Task { await model.startOverSlack() } }
            }
            .fixedSize()
            .disabled(model.isBusy)
            if let note = model.slackNote {
                Text(note)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.ok)
            }
            if let problem = model.slackProblem {
                Text(problem)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.accent)
            }
        }
    }

    private func copyManifest() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.slack.manifest, forType: .string)
        manifestCopied = true
    }
}
