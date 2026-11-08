import Foundation

/// HAIL-138: the live checklist after "Install plugin". Pure state machine, so the steps, the
/// rows and the detection of "seen" are tested without a window. It lives in `UserDefaults`
/// (via `PluginSetupSettings`) until the person presses Done or Skip.
struct PluginSetup: Codable, Equatable {
    /// When the install finished. Only live state from after this counts as "seen".
    var installedAt: Date
    /// An MCP entry existed before the install, so the "Old connection removed" row shows.
    var hadOldConnection: Bool
    var seenName: String?
    var seenTaskId: String?
    var seenAt: Date?
    var testAskAt: Date?
    /// Done or Skip: the card is gone for good.
    var finished = false

    enum Step: Equatable {
        /// Plugin installed, no Claude Code session reported through it yet.
        case waiting
        /// A session reported live state through the plugin.
        case seen
        /// That session also created an ask after the install.
        case working
    }

    static let testPrompt = "Ask me in Waggle which colour to use for the test button."

    var step: Step {
        if testAskAt != nil { return .working }
        return seenAt != nil ? .seen : .waiting
    }

    var isActive: Bool { !finished }

    init(installedAt: Date, hadOldConnection: Bool) {
        self.installedAt = installedAt
        self.hadOldConnection = hadOldConnection
    }

    /// The Claude Code session whose mod reported live state after the install, newest first.
    /// `context.live` exists only while the mod polls (HAIL-134), so its presence is the proof.
    static func seenSession(in sessions: [SessionInfo], after installedAt: Date) -> SessionInfo? {
        func reported(_ s: SessionInfo) -> Date? {
            guard s.runtime == .claude, s.state == .live, let live = s.context?.live else { return nil }
            // A timestamp this app cannot read must not hide a live mod: count it as just now.
            let at = KnockDateFormat.date(from: live.lastEventAt) ?? Date.distantFuture
            return at >= installedAt ? at : nil
        }
        return sessions
            .compactMap { s in reported(s).map { (s, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    /// "Seen in <name>": the session title, else its task name.
    static func displayName(of session: SessionInfo) -> String {
        if let title = session.context?.title, !title.isEmpty { return title }
        return session.taskName
    }

    /// Moves forward from what the daemon shows now. Never moves back. True when it changed.
    @discardableResult
    mutating func observe(sessions: [SessionInfo], cases: [Case], now: Date) -> Bool {
        guard isActive else { return false }
        var changed = false
        if seenAt == nil, let session = Self.seenSession(in: sessions, after: installedAt) {
            seenName = Self.displayName(of: session)
            seenTaskId = session.taskId
            seenAt = now
            changed = true
        }
        if seenAt != nil, testAskAt == nil, let taskId = seenTaskId, !taskId.isEmpty,
           let ask = cases.first(where: {
               $0.taskId == taskId && (KnockDateFormat.date(from: $0.createdAt) ?? .distantPast) >= installedAt
           }) {
            testAskAt = KnockDateFormat.date(from: ask.createdAt) ?? now
            changed = true
        }
        return changed
    }

    // MARK: Rows

    struct Row: Equatable {
        enum State: Equatable { case done, waiting }
        let title: String
        let state: State
    }

    /// The checklist, in order. The "old connection" row is dropped when there was none.
    func rows(now: Date) -> [Row] {
        var rows = [Row(title: "Plugin installed", state: .done)]
        if hadOldConnection { rows.append(Row(title: "Old connection removed", state: .done)) }
        if let name = seenName, let at = seenAt {
            rows.append(Row(title: "Seen in \(name) · \(KnockDateFormat.relativeShort(from: at, now: now))", state: .done))
        } else {
            rows.append(Row(title: "Waiting for a Claude Code session…", state: .waiting))
        }
        if testAskAt != nil { rows.append(Row(title: "Test decision arrived", state: .done)) }
        return rows
    }
}

enum PluginSetupSettings {
    private static let key = "pluginSetup"

    static func load(defaults: UserDefaults = .standard) -> PluginSetup? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(PluginSetup.self, from: $0) }
    }

    static func save(_ setup: PluginSetup?, defaults: UserDefaults = .standard) {
        if let setup, let data = try? JSONEncoder().encode(setup) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
