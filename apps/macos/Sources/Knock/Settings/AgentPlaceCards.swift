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

/// What the Agents rows say, so a test can read it. Steps come from each tool's own pages.
enum AgentPlaceCopy {
    static let download = "Download"
    static let claudeApp = "For chats and Cowork. Asks you to confirm first."
    static let claudeAppConnected = "Added to the Claude app settings. Backup kept."
    static let codexPlugin = "Plugin installed. Type /hooks in Codex to trust it once."
    static let superset = "Then run superset auth login in Terminal."
    static let conductor = "Waggle fills in your prompt. You press Enter."
}
