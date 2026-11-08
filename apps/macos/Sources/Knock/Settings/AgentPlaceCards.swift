import AppKit
import SwiftUI

/// WAG-278: which Settings › Agents card to scroll to. "Set up ›" in the Start menu sets it.
@MainActor
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var card: AgentPlaceCard?

    /// Asks for a card and brings the Agents page forward (a window that is open on another page too).
    func show(_ card: AgentPlaceCard, center: NotificationCenter = .default) {
        self.card = card
        center.post(name: .knockShowAgentsSettings, object: nil)
    }
}

/// What the cards say, so a test can read it. Steps come from each tool's own pages (see the story's Choices).
enum AgentPlaceCopy {
    static let supersetSignIn = "superset auth login"
    static let claudeApp = (
        title: "Claude app", subtitle: "Start ideas in the Claude app. Download it, then open it once.", button: "Download")
    static let codexApp = (
        title: "Codex app", subtitle: "Start ideas in the Codex app. Download it, then open it once.", button: "Download")
    static let supersetInstall = (
        title: "Install Superset", subtitle: "Download the app and open it once. It brings the superset command with it.",
        button: "Download")
    static let supersetSignInRow = (
        title: "Sign in", subtitle: "Run this line in Terminal, then add your folder as a project in Superset.")
    static let conductor = (
        title: "Conductor", subtitle: "Download the app. Waggle fills in your prompt and you press Enter.", button: "Download")
}

private func openInBrowser(_ url: URL) { NSWorkspace.shared.open(url) }

/// Short cards that say how to get each place. Waggle installs nothing: the links open in the browser.
struct AgentPlaceCards: View {
    var body: some View {
        card(label: "CLAUDE APP", id: .claudeApp, copy: AgentPlaceCopy.claudeApp, url: PlaceInstallLinks.claudeApp)
        card(label: "CODEX APP", id: .codexApp, copy: AgentPlaceCopy.codexApp, url: PlaceInstallLinks.codexApp)
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionLabel("SUPERSET")
            SettingsCard {
                SettingsCardRow(title: AgentPlaceCopy.supersetInstall.title, subtitle: AgentPlaceCopy.supersetInstall.subtitle) {
                    SettingsSecondaryButton(icon: "arrow.up.right", title: AgentPlaceCopy.supersetInstall.button) {
                        openInBrowser(PlaceInstallLinks.superset)
                    }
                }
                SettingsCardRow(
                    title: AgentPlaceCopy.supersetSignInRow.title, subtitle: AgentPlaceCopy.supersetSignInRow.subtitle,
                    showsDivider: false
                ) {
                    SettingsCopyButton(text: AgentPlaceCopy.supersetSignIn, label: "Copy line")
                }
            }
        }
        .id(AgentPlaceCard.superset)
        card(label: "CONDUCTOR", id: .conductor, copy: (AgentPlaceCopy.conductor.title, AgentPlaceCopy.conductor.subtitle, AgentPlaceCopy.conductor.button),
             url: PlaceInstallLinks.conductor)
    }

    private func card(
        label: String, id: AgentPlaceCard, copy: (title: String, subtitle: String, button: String), url: URL
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionLabel(label)
            SettingsCard {
                SettingsCardRow(title: copy.title, subtitle: copy.subtitle, showsDivider: false) {
                    SettingsSecondaryButton(icon: "arrow.up.right", title: copy.button) { openInBrowser(url) }
                }
            }
        }
        .id(id)
    }
}
