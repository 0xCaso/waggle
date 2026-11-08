import Foundation

/// The cards of Home, "What your agents are doing" (HAIL-191): one card per project or topic. Pure, so
/// the grouping, the state chip, the line and the summary are unit-tested without a window.
enum HomeCards {
    enum State: Int, Equatable {
        case waitingOnYou, working, decided, quiet

        var chip: String {
            switch self {
            case .waitingOnYou: "Waiting on you"
            case .working: "Working"
            case .decided: "Decided"
            case .quiet: "Quiet"
            }
        }
    }

    /// A small tile for one of the latest artifacts of the project.
    struct Thumb: Equatable, Identifiable {
        let caseId: String
        let icon: RequestRowModel.Icon
        var id: String { caseId }
    }

    struct Card: Equatable, Identifiable {
        /// The lower-cased project name: asks and sessions of one name share a card.
        let id: String
        let name: String
        let state: State
        /// One line of what is happening.
        let line: String
        /// "Claude Code", "Cowork": the agents behind the card, each once.
        let agents: [String]
        /// The newest artifacts first, at most `thumbLimit`.
        let thumbs: [Thumb]
        /// Only when a live session of the card reports a plan with steps.
        let progress: Progress?
        /// The ask a click opens: the one that needs you, else the newest.
        let openCaseId: String?
        let latestAt: Date
        /// "just now", "5m ago", "2h ago": the age of the newest activity, shown as a pill (HAIL-232).
        let ago: String
        /// Waiting, Working or Decided today: what Home shows by default.
        var isActive: Bool { state != .quiet }
        /// The daemon's project tag of the card, for its project page (WAG-260). Empty for a card built
        /// without one.
        var project: String = ""
        /// The descriptive title of the card's live session (WAG-279), nil when only the folder name is known.
        var sessionTitle: String? = nil
    }

    struct Progress: Equatable {
        let done: Int
        let total: Int
        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    struct Summary: Equatable {
        let waiting: Int
        let inProgress: Int
        let decidedToday: Int

        /// "2 things wait on you · 2 in progress · 1 decided today": only the parts above zero.
        var line: String {
            var parts: [String] = []
            if waiting > 0 { parts.append(waiting == 1 ? "1 thing waits on you" : "\(waiting) things wait on you") }
            if inProgress > 0 { parts.append("\(inProgress) in progress") }
            if decidedToday > 0 { parts.append("\(decidedToday) decided today") }
            return parts.isEmpty ? "Nothing is waiting on you" : parts.joined(separator: " · ")
        }
    }

    struct Overview: Equatable {
        let summary: Summary
        let cards: [Card]
        /// The cards Home shows by default (HAIL-232).
        var activeCards: [Card] { cards.filter(\.isActive) }
        /// The cards behind the collapsed "Quiet" row.
        var quietCards: [Card] { cards.filter { !$0.isActive } }
        static let empty = Overview(summary: Summary(waiting: 0, inProgress: 0, decidedToday: 0), cards: [])
    }

    static let thumbLimit = 3
    /// A quiet card older than this leaves Home: it is history, not what the agents are doing.
    static let quietMaxAge: TimeInterval = 7 * 24 * 3600

    /// `allCases` is every ask the app shows, answered ones too. `activeCases` is the subset that counts as
    /// open: asks that need you and asks still waiting on the agent.
    static func build(
        allCases: [Case], activeCases: [Case], sessions: [SessionInfo], now: Date,
        calendar: Calendar = .current
    ) -> Overview {
        let activeIds = Set(activeCases.map(\.id))
        let live = sessions.filter { $0.state == .live }
        var casesByKey: [String: [Case]] = [:]
        var names: [String: String] = [:]
        for item in allCases {
            let name = ProjectName.display(project: item.project)
            guard hasLetters(name) else { continue }
            let key = name.lowercased()
            casesByKey[key, default: []].append(item)
            names[key] = names[key] ?? name
        }
        var sessionsByKey: [String: [SessionInfo]] = [:]
        for session in live {
            // A session belongs to the card of its asks; one with no asks yet has the card of its project.
            let owned = SessionActivity.asks(for: session, in: allCases).first
            let name = owned.map { ProjectName.display(project: $0.project) } ?? ProjectName.display(project: session.project)
            guard hasLetters(name) else { continue }
            let key = name.lowercased()
            sessionsByKey[key, default: []].append(session)
            names[key] = names[key] ?? name
        }

        let cards = names.keys.map { key -> Card in
            let cases = (casesByKey[key] ?? []).sorted(by: newestFirst)
            let keySessions = sessionsByKey[key] ?? []
            return card(
                key: key, name: names[key] ?? key, cases: cases, sessions: keySessions,
                activeIds: activeIds, activeCases: activeCases, now: now, calendar: calendar)
        }.filter { $0.state != .quiet || now.timeIntervalSince($0.latestAt) < quietMaxAge }.sorted { l, r in
            if l.state != r.state { return l.state.rawValue < r.state.rawValue }
            if l.latestAt != r.latestAt { return l.latestAt > r.latestAt }
            return l.name < r.name
        }

        let waiting = allCases.filter { activeIds.contains($0.id) && $0.status == .needsYou }.count
        let decided = allCases.filter { !activeIds.contains($0.id) && settledToday($0, now: now, calendar: calendar) }.count
        let summary = Summary(waiting: waiting, inProgress: cards.filter { $0.state == .working }.count, decidedToday: decided)
        return Overview(summary: summary, cards: cards)
    }

    private static func card(
        key: String, name: String, cases: [Case], sessions: [SessionInfo], activeIds: Set<String>,
        activeCases: [Case], now: Date, calendar: Calendar
    ) -> Card {
        let needsYou = cases.first { activeIds.contains($0.id) && $0.status == .needsYou }
        let waiting = cases.first { activeIds.contains($0.id) && $0.status == .waitingOnAgent && !$0.isDone }
        let workingSession = sessions.first { AgentStatus.forSession($0, cases: activeCases) == .working }
        let newest = cases.first
        let settled = cases.first { !activeIds.contains($0.id) && settledToday($0, now: now, calendar: calendar) }

        let state: State
        let line: String
        if let needsYou {
            state = .waitingOnYou
            line = needsYou.rowTitle
        } else if waiting != nil || workingSession != nil {
            state = .working
            line = workingLine(waiting: waiting, session: workingSession, now: now)
        } else if let settled {
            state = .decided
            line = decidedLine(settled)
        } else {
            state = .quiet
            line = newest?.rowTitle ?? sessions.first.map { RightNowList.summary($0, hasAsks: false) } ?? "No decisions yet"
        }

        var agents: [String] = []
        for label in cases.map(\.runtimeLabel) + sessions.map(\.runtimeLabel) where !agents.contains(label) {
            agents.append(label)
        }
        let thumbs = cases.compactMap { item -> Thumb? in
            guard let icon = RequestRowModel.iconFor(item.artifactKind) else { return nil }
            return Thumb(caseId: item.id, icon: icon)
        }.prefix(thumbLimit)
        // A bar shows only while the card works and a live session reports a plan with steps.
        let progress = state != .working ? nil : sessions.lazy.compactMap { $0.context?.plan }.first { $0.total > 0 }
            .map { Progress(done: min(max($0.done, 0), $0.total), total: $0.total) }
        let latestAt = (cases.compactMap { latestMoment($0) } + sessions.compactMap { AgentStatus.lastActivity($0, cases: cases) }).max()
            ?? .distantPast
        return Card(
            id: key, name: name, state: state, line: line, agents: agents, thumbs: Array(thumbs),
            progress: progress, openCaseId: (needsYou ?? newest)?.id, latestAt: latestAt,
            ago: latestAt == .distantPast ? "" : CaseTimes.agoLabel(since: latestAt, now: now),
            project: cases.first?.project ?? sessions.first?.project ?? "",
            sessionTitle: (([workingSession].compactMap { $0 }) + sessions).lazy.compactMap(SessionTitle.pick).first)
    }

    private static func workingLine(waiting: Case?, session: SessionInfo?, now: Date) -> String {
        if let doing = SessionContextDisplay.doingNow(session?.context, now: now) {
            // The age is the card's time pill, not part of the line.
            return SessionContextDisplay.lastActionText(session?.context) ?? doing
        }
        if let current = session?.context?.plan?.current, !current.isEmpty { return current }
        if let waiting { return "Working on your answer: \(waiting.rowTitle)" }
        return session.map { RightNowList.summary($0, hasAsks: false) } ?? "Working"
    }

    private static func decidedLine(_ item: Case) -> String {
        if item.isDone { return item.doneMessage.isEmpty ? "Done: \(item.rowTitle)" : "Done: \(item.doneMessage)" }
        if let answer = RightNowList.answerText(item), !answer.isEmpty { return "You decided: \(answer)" }
        return item.rowTitle
    }

    /// True when you answered the ask, or the agent closed it, today.
    static func settledToday(_ item: Case, now: Date, calendar: Calendar = .current) -> Bool {
        let at: Date? = item.isDone ? (item.doneAtDate ?? item.updatedAtDate) : item.latestReplyAtDate ?? item.firstReplySubmittedAtDate
        guard let at else { return false }
        return calendar.isDate(at, inSameDayAs: now)
    }

    private static func latestMoment(_ item: Case) -> Date? {
        [item.createdAtDate, item.latestReplyAtDate, item.doneAtDate, item.updatedAtDate].compactMap { $0 }.max()
    }

    private static func newestFirst(_ l: Case, _ r: Case) -> Bool {
        let ld = l.createdAtDate ?? .distantPast, rd = r.createdAtDate ?? .distantPast
        return ld != rd ? ld > rd : l.id > r.id
    }

    private static func hasLetters(_ text: String) -> Bool { text.contains { $0.isLetter || $0.isNumber } }
}
