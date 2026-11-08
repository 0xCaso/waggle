import Foundation

// WAG-278: the shorter Start menu. A Claude Code | Codex switch, then one row per place.
// Usable places come first. Places that cannot work for the chosen agent fold into one line.

/// The agent the menu's switch picks.
enum LaunchAgent: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex

    var id: String { rawValue }
    var title: String { self == .claude ? "Claude Code" : "Codex" }
}

/// Where the agent runs. Declaration order is the row order inside each group.
enum LaunchPlace: String, CaseIterable, Identifiable, Sendable {
    case terminal
    case app
    case superset
    case conductor
    case t3

    var id: String { rawValue }

    /// The row title: the place, in words ("Claude app" for the agent's own app).
    func title(for agent: LaunchAgent) -> String {
        switch self {
        case .terminal: return "Terminal"
        case .app: return agent == .claude ? "Claude app" : "Codex app"
        case .superset: return "Superset"
        case .conductor: return "Conductor"
        case .t3: return "T3 Code"
        }
    }

    /// The Settings › Agents card that says how to get this place.
    func settingsCard(for agent: LaunchAgent) -> AgentPlaceCard {
        switch self {
        case .terminal: return .runtimes
        case .app: return agent == .claude ? .claudeApp : .codexApp
        case .superset: return .superset
        case .conductor: return .conductor
        case .t3: return .t3
        }
    }
}

/// The cards on Settings › Agents that a "Set up ›" link can scroll to.
enum AgentPlaceCard: String, CaseIterable, Identifiable, Sendable {
    case runtimes, claudeApp, codexApp, superset, conductor, t3
    var id: String { rawValue }
}

extension LaunchTarget {
    /// The agent this target runs. Conductor uses its own app default, so it has none.
    var agent: LaunchAgent? {
        switch self {
        case .claudeTerminal, .claudeApp, .claudeSuperset, .claudeT3: return .claude
        case .codexTerminal, .codexApp, .codexSuperset, .codexT3: return .codex
        case .conductor: return nil
        }
    }

    var place: LaunchPlace {
        switch self {
        case .claudeTerminal, .codexTerminal: return .terminal
        case .claudeApp, .codexApp: return .app
        case .claudeSuperset, .codexSuperset: return .superset
        case .conductor: return .conductor
        case .claudeT3, .codexT3: return .t3
        }
    }

    static func target(agent: LaunchAgent, place: LaunchPlace) -> LaunchTarget {
        switch (place, agent) {
        case (.terminal, .claude): return .claudeTerminal
        case (.terminal, .codex): return .codexTerminal
        case (.app, .claude): return .claudeApp
        case (.app, .codex): return .codexApp
        case (.superset, .claude): return .claudeSuperset
        case (.superset, .codex): return .codexSuperset
        case (.conductor, _): return .conductor
        case (.t3, .claude): return .claudeT3
        case (.t3, .codex): return .codexT3
        }
    }

    /// The target after the switch moves to `agent`: the same place when it works for the new
    /// agent, else Terminal.
    func switching(to agent: LaunchAgent, availability: LaunchAvailability) -> LaunchTarget {
        let same = LaunchTarget.target(agent: agent, place: place)
        if availability.isAvailable(same) { return same }
        return LaunchTarget.target(agent: agent, place: .terminal)
    }
}

extension LaunchAvailability {
    /// Why a place cannot work for the agent, in plain words, or nil when it can.
    func reason(_ place: LaunchPlace, agent: LaunchAgent) -> String? {
        let target = LaunchTarget.target(agent: agent, place: place)
        guard !isAvailable(target) else { return nil }
        if place == .terminal { return "\(agent.title) not found on this Mac" }
        return unavailableText(target)
    }
}

/// One place row in the menu.
struct StartMenuRow: Equatable, Identifiable {
    let place: LaunchPlace
    let title: String
    /// Status line, only when it says something the title does not.
    let subtitle: String?
    /// Set on a place to set up: why it cannot work now.
    let reason: String?
    var id: LaunchPlace { place }
}

struct StartMenuLayout: Equatable {
    let agent: LaunchAgent
    let usable: [StartMenuRow]
    let setup: [StartMenuRow]

    /// "2 more places to set up", or nil when every place works.
    var foldTitle: String? {
        guard !setup.isEmpty else { return nil }
        return "\(setup.count) more \(setup.count == 1 ? "place" : "places") to set up"
    }

    static func make(agent: LaunchAgent, availability: LaunchAvailability) -> StartMenuLayout {
        var usable: [StartMenuRow] = []
        var setup: [StartMenuRow] = []
        for place in LaunchPlace.allCases {
            let title = place.title(for: agent)
            if let reason = availability.reason(place, agent: agent) {
                setup.append(StartMenuRow(place: place, title: title, subtitle: nil, reason: reason))
            } else {
                let subtitle = place == .conductor ? "Prompt filled in, you press Enter" : nil
                usable.append(StartMenuRow(place: place, title: title, subtitle: subtitle, reason: nil))
            }
        }
        return StartMenuLayout(agent: agent, usable: usable, setup: setup)
    }
}

/// The sessions submenu: working sessions first, each group in its given order.
enum StartMenuSessions {
    static func ordered(_ options: [DocumentSendOption]) -> [DocumentSendOption] {
        options.filter(\.isWorking) + options.filter { !$0.isWorking }
    }

    /// "3 sessions" under the row title.
    static func countText(_ count: Int) -> String { count == 1 ? "1 session" : "\(count) sessions" }
}

/// Where each "Set up" link and the footer link send the person in Settings.
enum StartMenuSettingsRoute {
    static let footerTitle = "Places in Settings"

    /// The card for a place. The footer link has no place and lands on the first card, the agents.
    static func card(for place: LaunchPlace?, agent: LaunchAgent) -> AgentPlaceCard {
        place?.settingsCard(for: agent) ?? .runtimes
    }
}

/// Download pages for the places Waggle does not install. Links open in the browser.
enum PlaceInstallLinks {
    static let claudeApp = URL(string: "https://claude.ai/download")!
    static let codexApp = URL(string: "https://developers.openai.com/codex/app")!
    static let superset = URL(string: "https://superset.sh")!
    static let conductor = URL(string: "https://www.conductor.build")!
    static let t3 = URL(string: "https://t3.codes")!
}
