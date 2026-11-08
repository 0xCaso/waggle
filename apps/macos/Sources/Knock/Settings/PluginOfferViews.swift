import SwiftUI
import AppKit

/// The offer copy, shared by the Home card and the Settings row (HAIL-136).
enum PluginOfferCopy {
    static let title = "Waggle now has a Claude Code plugin"
    static let body = "It shows when an agent is waiting on you right above the prompt, tells Waggle what each session is doing, and makes Nudge more reliable. It runs inside Claude Code with your permissions."
    static let install = "Install plugin"
    static let notNow = "Not now"
    static let toggleTitle = "Claude Code plugin"
    static let toggleHelp = "On adds the plugin to Claude Code. Off connects through a plain MCP entry instead."
}

/// HAIL-138 copy for the checklist after the install.
enum PluginSetupCopy {
    static let title = "Setting up the Claude Code plugin"
    static let workingTitle = "Claude Code plugin is working"
    static let waitingHint = "Start a new session or restart an open one, then try it:"
    static let bandLine = "When an agent waits on you, Waggle shows above its prompt (after a minute)."
    static let copy = "Copy test prompt"
    static let copied = "Copied"
    static let skip = "Skip"
    static let done = "Done"
}

/// One checklist row: a tick or a waiting dot, the label, and an optional line under it.
private struct PluginSetupRow: View {
    let row: PluginSetup.Row
    var sub: String?
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .knockTextStyle(Theme.Typography.rowTitle13_5w600)
                    .foregroundColor(row.state == .done ? Theme.Colors.ink : Theme.Colors.ink2)
                if let sub {
                    Text(sub)
                        .knockTextStyle(Theme.Typography.body12_5w400)
                        .foregroundColor(Theme.Colors.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var icon: some View {
        ZStack {
            Circle().fill(row.state == .done ? Theme.Colors.ok : Theme.Colors.win)
            if row.state == .done {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.Colors.onFill)
            } else {
                Circle().stroke(Theme.Colors.line2, lineWidth: 1.5)
                Circle().fill(Theme.Colors.ink3).frame(width: 6, height: 6)
            }
        }
        .frame(width: 20, height: 20)
    }
}

/// The checklist rows, shared by the Home card and the compact Settings block.
struct PluginSetupChecklist: View {
    let setup: PluginSetup
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(setup.rows(now: now).enumerated()), id: \.offset) { _, row in
                PluginSetupRow(row: row, sub: sub(for: row))
            }
            if setup.step == .waiting {
                Text(PluginSetupCopy.waitingHint)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.ink3)
                promptBox
            }
        }
    }

    private func sub(for row: PluginSetup.Row) -> String? {
        row.title.hasPrefix("Seen in") && setup.step == .working ? PluginSetupCopy.bandLine : nil
    }

    private var promptBox: some View {
        Text(PluginSetup.testPrompt)
            .knockTextStyle(Theme.Typography.monoMeta12w400)
            .foregroundColor(Theme.Colors.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.side)
            .cornerRadius(8)
    }
}

/// "Copy test prompt" (shows "Copied" after) and "Skip".
private struct PluginSetupWaitingButtons: View {
    @ObservedObject var offer: PluginOfferModel
    /// Evidence only: `KNOCK_EVIDENCE_PLUGIN_COPIED=1` starts in the "Copied" state.
    @State private var copied = ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_PLUGIN_COPIED"] == "1"

    var body: some View {
        HStack(spacing: 8) {
            SettingsPrimaryButton(title: copied ? PluginSetupCopy.copied : PluginSetupCopy.copy) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(PluginSetup.testPrompt, forType: .string)
                copied = true
            }
            SettingsSecondaryButton(title: PluginSetupCopy.skip) { offer.finishSetup() }
        }
    }
}

/// The dark preview of the line the plugin draws above the Claude Code prompt.
private struct PluginBandPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            (Text("Waggle").foregroundColor(Theme.Colors.accent).fontWeight(.bold)
                + Text(" · still waiting on your answer · 2m · 1: open").foregroundColor(Theme.Colors.bandPreviewText))
                .knockTextStyle(Theme.Typography.monoMeta11_5w400)
            Text("❯")
                .knockTextStyle(Theme.Typography.monoMeta11_5w400)
                .foregroundColor(Theme.Colors.bandPreviewPrompt)
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.bandPreviewFill)
        .cornerRadius(8)
    }
}

/// Home: the setup card (variant C) that turns green once a test ask arrived (B2).
struct PluginSetupCard: View {
    @ObservedObject var offer: PluginOfferModel
    let setup: PluginSetup

    var body: some View {
        let working = setup.step == .working
        TimelineView(.periodic(from: .now, by: 20)) { context in
            VStack(alignment: .leading, spacing: 12) {
                Text(working ? PluginSetupCopy.workingTitle : PluginSetupCopy.title)
                    .knockTextStyle(Theme.Typography.cardTitle15w650)
                    .foregroundColor(Theme.Colors.ink)
                PluginSetupChecklist(setup: setup, now: context.date)
                if working { PluginBandPreview() }
                if working {
                    SettingsPrimaryButton(title: PluginSetupCopy.done) { offer.finishSetup() }
                } else if setup.step == .waiting {
                    PluginSetupWaitingButtons(offer: offer)
                } else {
                    SettingsSecondaryButton(title: PluginSetupCopy.skip) { offer.finishSetup() }
                }
            }
            .padding(EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20))
            .frame(maxWidth: 560, alignment: .leading)
            .background(working ? Theme.Colors.okSoft : Theme.Colors.win)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Colors.line, lineWidth: 1))
        }
    }
}

/// "Installing…" or the failure line, under the offer's buttons.
private struct PluginOfferProgress: View {
    let phase: PluginOfferModel.Phase

    var body: some View {
        switch phase {
        case .working:
            LoadingStatus(label: "Installing")
        case .failed(let message):
            Text(message)
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(Theme.Colors.accent)
                .fixedSize(horizontal: false, vertical: true)
        case .idle, .done:
            EmptyView()
        }
    }
}

/// The dismissible card on Home, above "Right now" / the caught-up header.
struct PluginOfferCard: View {
    @ObservedObject var offer: PluginOfferModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(PluginOfferCopy.title)
                .knockTextStyle(Theme.Typography.rowTitle13_5w600)
                .foregroundColor(Theme.Colors.ink)
            Text(PluginOfferCopy.body)
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(Theme.Colors.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                SettingsPrimaryButton(title: PluginOfferCopy.install) {
                    Task { await offer.setPlugin(on: true) }
                }
                SettingsSecondaryButton(title: PluginOfferCopy.notNow) { offer.dismiss() }
                PluginOfferProgress(phase: offer.phase)
            }
            .disabled(offer.isWorking)
        }
        .padding(16)
        .frame(maxWidth: 560, alignment: .leading)
        .background(Theme.Colors.accentSoft)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Colors.line, lineWidth: 1))
    }
}

/// Settings › Agents: the offer row (no "Not now": the row stays) and the On/Off control.
struct PluginSettingsRows: View {
    @ObservedObject var offer: PluginOfferModel

    var body: some View {
        if offer.status.showsToggle {
            SettingsCard {
                if offer.status.showsSettingsOffer {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(PluginOfferCopy.title)
                            .knockTextStyle(Theme.Typography.rowTitle13_5w600)
                            .foregroundColor(Theme.Colors.ink)
                        Text(PluginOfferCopy.body)
                            .knockTextStyle(Theme.Typography.body12_5w400)
                            .foregroundColor(Theme.Colors.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            SettingsPrimaryButton(title: PluginOfferCopy.install) {
                                Task { await offer.setPlugin(on: true) }
                            }
                            .disabled(offer.isWorking)
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(Theme.Colors.line).frame(height: 1)
                }
                SettingsCardRow(title: PluginOfferCopy.toggleTitle, subtitle: PluginOfferCopy.toggleHelp, showsDivider: false) {
                    HStack(spacing: 10) {
                        if offer.isWorking { LoadingStatus(label: "Working") }
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { offer.status.isPluginOn },
                                set: { on in Task { await offer.setPlugin(on: on) } }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch).pointerCursor()
                        .disabled(offer.isWorking)
                    }
                }
                if offer.showsSetupCard, let setup = offer.setup {
                    Rectangle().fill(Theme.Colors.line).frame(height: 1)
                    TimelineView(.periodic(from: .now, by: 20)) { context in
                        VStack(alignment: .leading, spacing: 10) {
                            PluginSetupChecklist(setup: setup, now: context.date)
                            if setup.step == .waiting { PluginSetupWaitingButtons(offer: offer) }
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                switch offer.phase {
                case .failed(let message):
                    resultLine(message, color: Theme.Colors.accent)
                case .done(let message):
                    resultLine(message, color: Theme.Colors.ok)
                case .idle, .working:
                    EmptyView()
                }
            }
        }
    }

    private func resultLine(_ text: String, color: Color) -> some View {
        Text(text)
            .knockTextStyle(Theme.Typography.body12_5w400)
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
