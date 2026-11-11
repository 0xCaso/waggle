import Foundation

/// The one thing a row of setup step 1 offers. Pure: the view only draws it.
enum ConnectRowAction: Equatable {
    /// The agent is found and not connected yet.
    case connect
    /// The agent is not found: opens its install page.
    case get(URL)
    /// Done. A state, not a control.
    case connected
    /// A check or a connect is running.
    case working
    /// Nothing to press. "Check again" is the way out.
    case none
}

enum ConnectStepRules {
    /// Where "Get" goes for each agent. A link opens in the browser: Waggle makes no request itself.
    static func installURL(for runtime: Runtime) -> URL {
        switch runtime {
        case .claude: URL(string: "https://docs.claude.com/en/docs/claude-code/overview")!
        case .codex: URL(string: "https://developers.openai.com/codex/cli")!
        }
    }

    /// The Claude app has no install probe. It always offers Connect, then shows connected.
    static func claudeAppAction(isConnected: Bool) -> ConnectRowAction {
        isConnected ? .connected : .connect
    }

    static func action(for runtime: Runtime, status: OnboardingModel.RuntimeRow.Status) -> ConnectRowAction {
        switch status {
        case .notConnected: .connect
        case .notInstalled: .get(installURL(for: runtime))
        case .connected: .connected
        case .probing, .connecting: .working
        case .couldNotCheck: .none
        }
    }

    /// "Skip for now" leaves setup at every point of step 1: no agent, a failed check, a row mid-connect.
    static func skipIsAvailable(on screen: OnboardingModel.Screen) -> Bool { screen == .connect }

    /// "Check again" runs the search again. Not while one search is already running.
    static func checkAgainIsAvailable(phase: OnboardingModel.ConnectPhase) -> Bool {
        if case .loaded(let rows) = phase { return !rows.contains { $0.status == .connecting } }
        return false
    }
}
