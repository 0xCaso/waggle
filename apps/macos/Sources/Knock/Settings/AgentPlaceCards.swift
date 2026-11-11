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

/// The cards on Settings › Agents that a "Set up ›" link can scroll to.
enum AgentPlaceCard: String, CaseIterable, Identifiable, Sendable {
    case runtimes, claudeApp, codexApp, superset, conductor, t3
    var id: String { rawValue }
}

/// Download pages for the places Waggle does not install. Links open in the browser.
enum PlaceInstallLinks {
    static let claudeApp = URL(string: "https://claude.ai/download")!
    static let codexApp = URL(string: "https://developers.openai.com/codex/app")!
    static let superset = URL(string: "https://superset.sh")!
    static let conductor = URL(string: "https://www.conductor.build")!
    static let t3 = URL(string: "https://t3.codes")!
}
