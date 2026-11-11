import Foundation

/// The first job of the new onboarding (WAG-338, step 2 "What are you working on?"). Pure logic, so the
/// project list, the suggestions, the prompt and the choice of session are unit-tested without a window.
/// Everything here reads Waggle's own data only (sessions and asks the daemon holds). It never reads a
/// Claude Code transcript or anything under ~/.claude.

/// One project of the project row. A real one comes from a session the daemon knows; "Something else"
/// is the folder picker.
struct OnboardingProject: Equatable, Identifiable {
    /// The lower-cased display name, or "other" for a folder picked by hand.
    let id: String
    /// The name in plain words ("Acme support"), never a path.
    let name: String
    /// Where a new session starts. Nil only for the "Something else" tile before a folder is picked.
    let folder: String?
    /// The small line under the name: "Claude Code · open now".
    let detail: String
    let isSomethingElse: Bool

    static let somethingElse = OnboardingProject(
        id: "other", name: "Something else", folder: nil, detail: "Pick a folder", isSomethingElse: true)

    /// A project the person picked by hand with the folder picker.
    static func picked(folder: URL) -> OnboardingProject {
        let name = ProjectName.readable(folder: folder.path)
        return OnboardingProject(
            id: "other", name: name.isEmpty ? folder.lastPathComponent : name, folder: folder.path,
            detail: "Your folder", isSomethingElse: true)
    }

    /// The key two sessions or asks share when they are about the same project.
    static func key(forProject project: String) -> String {
        ProjectName.display(project: project).lowercased()
    }
}

enum OnboardingProjects {
    /// How many recent projects show before "Something else".
    static let limit = 3

    /// Recent projects from the sessions the daemon knows, newest first. A session with no folder (the
    /// Claude app, Cowork) and the throwaway folder of `waggle test-ask` are left out: nothing can start
    /// there. "Something else" always comes last.
    static func build(sessions: [SessionInfo], now: Date) -> [OnboardingProject] {
        let usable = sessions.filter { isUsable($0) }
        var order: [String] = []
        var newest: [String: SessionInfo] = [:]
        var open: Set<String> = []
        for session in usable.sorted(by: { seen($0) > seen($1) }) {
            let key = OnboardingProject.key(forProject: session.project)
            guard !key.isEmpty else { continue }
            if newest[key] == nil {
                newest[key] = session
                order.append(key)
            }
            if FirstJobSessions.canTakeJob(session) { open.insert(key) }
        }
        var projects = order.prefix(limit).compactMap { key -> OnboardingProject? in
            guard let session = newest[key] else { return nil }
            let isOpen = open.contains(key)
            let when = isOpen ? "open now" : FirstJobWords.since(seen(session), now: now)
            return OnboardingProject(
                id: key, name: ProjectName.display(project: session.project), folder: session.cwd,
                detail: "\(session.runtime.displayName) · \(when)", isSomethingElse: false)
        }
        projects.append(.somethingElse)
        return projects
    }

    static func isUsable(_ session: SessionInfo) -> Bool {
        !session.cwd.isEmpty && !session.cwd.contains("/knock-test-ask-")
    }

    static func seen(_ session: SessionInfo) -> Date {
        KnockDateFormat.date(from: session.lastSeenAt) ?? .distantPast
    }
}

/// Which sessions can take a job from Waggle. The same rule as the New idea page
/// (`SendHelpers.sendableSessions`): live Claude Code with a way to wake it.
enum FirstJobSessions {
    static func canTakeJob(_ session: SessionInfo) -> Bool {
        session.state == .live && session.runtime == .claude && session.canNudge
    }
}

/// One suggested job from Waggle's history.
struct FirstJobSuggestion: Equatable, Identifiable {
    let title: String
    /// "From your session yesterday." / "From your decision last week."
    let source: String
    var id: String { title.lowercased() }
}

enum FirstJobKind: Equatable {
    /// "Let the agent find a real decision": the default.
    case findDecision
    case suggestion(FirstJobSuggestion)
    case own(String)
}

enum FirstJobSuggestions {
    static let limit = 3
    static let titleMaxLength = 70

    /// Two or three suggestions for a project, newest first, from the titles of the sessions (the title the
    /// agent sent) and of the asks Waggle holds. No history gives none. A title that looks like code, a
    /// repeat, and the sample ask are left out. Never reads a transcript: `SessionInfo.context` is not used.
    static func build(project: OnboardingProject, sessions: [SessionInfo], cases: [Case], now: Date) -> [FirstJobSuggestion] {
        guard !project.isSomethingElse || project.folder != nil else { return [] }
        let key = project.id == "other" ? OnboardingProject.key(forProject: project.name) : project.id
        var candidates: [(date: Date, suggestion: FirstJobSuggestion)] = []
        for session in sessions where OnboardingProject.key(forProject: session.project) == key {
            guard let raw = session.sessionTitle, let title = usable(raw, session: session) else { continue }
            let date = OnboardingProjects.seen(session)
            candidates.append((date, FirstJobSuggestion(title: title, source: "From your session \(FirstJobWords.since(date, now: now, sentence: true)).")))
        }
        for item in cases where OnboardingProject.key(forProject: item.project) == key {
            guard let title = usable(item.title, session: nil), !SampleAsk.isSample(item) else { continue }
            let date = item.createdAtDate ?? .distantPast
            candidates.append((date, FirstJobSuggestion(title: title, source: "From your decision \(FirstJobWords.since(date, now: now, sentence: true)).")))
        }
        var seen: Set<String> = []
        var result: [FirstJobSuggestion] = []
        for candidate in candidates.sorted(by: { $0.date > $1.date }) where seen.insert(candidate.suggestion.id).inserted {
            result.append(candidate.suggestion)
            if result.count == limit { break }
        }
        return result
    }

    private static func usable(_ raw: String, session: SessionInfo?) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= titleMaxLength, !SessionTitle.looksLikeCode(text, session: session) else { return nil }
        return text
    }
}

/// The prompt Waggle sends or copies. Plain words for the agent: it is agent-facing text, so "ask" is fine.
enum FirstJobPrompt {
    static let closing = "Scout 2 or 3 options, with a prototype or a write-up for each. Send them to me in Waggle (waggle_ask) with your pick and why."

    static func build(_ kind: FirstJobKind, projectName: String) -> String {
        switch kind {
        case .findDecision:
            return "Look at this project (\(projectName)): the code, the recent commits and the open TODOs. "
                + "Pick one real open decision. \(closing)"
        case .suggestion(let suggestion):
            return "In this project (\(projectName)), I want to decide this: \(suggestion.title). \(closing)"
        case .own(let text):
            return "In this project (\(projectName)), I want to decide this: \(text.trimmingCharacters(in: .whitespacesAndNewlines)). \(closing)"
        }
    }

    /// What the working card says the agent is doing.
    static func summary(_ kind: FirstJobKind) -> String {
        switch kind {
        case .findDecision: return AgentOnIt.defaultSummary
        case .suggestion(let suggestion): return suggestion.title
        case .own(let text): return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The topic the launcher shows for a new session.
    static func topic(_ kind: FirstJobKind) -> String {
        switch kind {
        case .findDecision: return "Find a real decision"
        case .suggestion(let suggestion): return suggestion.title
        case .own(let text): return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// Where the job goes.
struct OpenSessionChoice: Equatable {
    let sessionId: String
    let agentName: String
    let startedAt: Date?
    let title: String?
}

enum FirstJobRoute: Equatable {
    case session(OpenSessionChoice)
    /// A new Claude Code session in Terminal, in the project folder.
    case terminal
}

/// The routes for one project and the one in use. "Change" steps to the next route.
struct FirstJobRouting: Equatable {
    private(set) var routes: [FirstJobRoute]
    private(set) var index = 0

    init(routes: [FirstJobRoute]) { self.routes = routes.isEmpty ? [.terminal] : routes }

    var current: FirstJobRoute { routes[min(index, routes.count - 1)] }
    var canChange: Bool { routes.count > 1 }
    var usesOpenSession: Bool { if case .session = current { return true } else { return false } }

    mutating func change() {
        guard canChange else { return }
        index = (index + 1) % routes.count
    }

    /// Open Claude Code sessions in the project first (live, with the Waggle plugin, newest first), then
    /// a new session in Terminal as the last route. With no open session only Terminal is left.
    static func make(project: OnboardingProject, sessions: [SessionInfo]) -> FirstJobRouting {
        let key = project.id == "other" ? OnboardingProject.key(forProject: project.name) : project.id
        let matches = sessions.filter(FirstJobSessions.canTakeJob).filter {
            OnboardingProject.key(forProject: $0.project) == key || (project.folder != nil && $0.cwd == project.folder)
        }.sorted { OnboardingProjects.seen($0) > OnboardingProjects.seen($1) }
        let open = matches.map { session in
            FirstJobRoute.session(OpenSessionChoice(
                sessionId: session.id, agentName: session.runtime.displayName,
                startedAt: KnockDateFormat.date(from: session.connectedAt), title: SessionTitle.pick(session)))
        }
        return FirstJobRouting(routes: open + [.terminal])
    }

    /// The line over the footer. Names the session before anything is sent.
    func line(projectName: String, calendar: Calendar = .current) -> String {
        switch current {
        case .session(let choice):
            var line = "Sends to your open \(choice.agentName) session in \(projectName)"
            if let startedAt = choice.startedAt { line += " (started \(FirstJobWords.clock(startedAt, calendar: calendar)))" }
            return line + "."
        case .terminal:
            return canChange
                ? "Waggle starts a new Claude Code session in \(projectName) in Terminal, with the prompt in it."
                : "No open session in \(projectName). Waggle starts Claude Code in Terminal with the prompt in it."
        }
    }

    /// Who takes the job.
    var agentName: String {
        if case .session(let choice) = current { return choice.agentName }
        return "Claude Code"
    }

    var startLabel: String { usesOpenSession ? "Send to my session" : "Start in Terminal" }
}

enum FirstJobWords {
    /// "today", "yesterday", "3 days ago", "last week", "2 weeks ago". With `sentence`, "yesterday" stays
    /// as it is and "today" reads "earlier today".
    static func since(_ date: Date, now: Date, sentence: Bool = false, calendar: Calendar = .current) -> String {
        guard date != .distantPast else { return "a while ago" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return sentence ? "earlier today" : "today"
        case 1: return "yesterday"
        case 2..<7: return "\(days) days ago"
        case 7..<14: return "last week"
        case 14..<60: return "\(days / 7) weeks ago"
        default: return "a while ago"
        }
    }

    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
