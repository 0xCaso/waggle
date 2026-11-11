import AppKit
import Foundation

/// Small helpers that setup, onboarding and the answer flow share: the folder picker, the failure
/// words for a prompt that did not arrive, and which sessions can take a prompt.
enum SendHelpers {
    /// The UserDefaults key of the folder the person picked last.
    static let folderKey = "NewIdeaFolder"

    /// Live Claude Code sessions that can receive a prompt. Codex, closed and no-nudge sessions
    /// are left out.
    static func sendableSessions(_ sessions: [SessionInfo]) -> [SessionInfo] {
        sessions.filter { $0.state == .live && $0.runtime == .claude && $0.canNudge }
    }

    static func failureText(_ reason: SendPromptFailureReason?) -> String {
        switch reason {
        case .sessionClosed: return "That session has closed. Pick another one, or start a new session."
        case .notSupported: return "That session cannot take a prompt from Waggle. Start a new session instead."
        case .postFailed, .none: return "The prompt did not arrive. Try again, or start a new session."
        }
    }

    /// The real picker. No test reaches it.
    static func openFolderPanel(startingAt folder: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
