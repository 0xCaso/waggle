import Foundation

/// What one live session is doing, derived only from data Knock already has
/// (HAIL-59): the session's own `SessionInfo` and the open asks of its task.
/// Pure functions of their inputs, so the "now" rule and the counts are
/// unit-testable without a daemon or a clock.
struct SessionActivity: Equatable {
    enum Kind: Equatable {
        /// An ask needs the human. Dot: hail.
        case needsYou
        /// The latest reply is queued, not yet picked up. Dot: ds blue.
        case waitingForPickup
        /// The latest reply was delivered and the agent is working. Dot: ds blue.
        case working
        /// Connected, nothing open. Dot: ok green.
        case idle
    }

    let kind: Kind
    /// The "now" line, shown on the row and on the detail's NOW card.
    let nowLine: String
    let needsYouCount: Int
    let waitingCount: Int
    /// The right-hand "seen 20s ago" / "asked 2m ago" / "idle 12m" label.
    let lastSeenLabel: String

    /// The asks of the session's task. A session with no task id (an older
    /// daemon) has none.
    static func asks(for session: SessionInfo, in cases: [Case]) -> [Case] {
        guard !session.taskId.isEmpty else { return [] }
        return cases.filter { $0.taskId == session.taskId }
    }

    static func make(session: SessionInfo, cases: [Case], now: Date) -> SessionActivity {
        let asks = asks(for: session, in: cases)
        let needsYou = asks.filter { $0.status == .needsYou }
        let waiting = asks.filter { $0.status == .waitingOnAgent }
        let (kind, line) = nowState(asks: asks, now: now)

        let lastSeen: String
        if let newest = needsYou.compactMap({ KnockDateFormat.date(from: $0.createdAt) }).max() {
            lastSeen = "asked \(ago(since: newest, now: now))"
        } else {
            // HAIL-178: idle counts from the last activity. A heartbeat is not activity, so
            // `lastSeenAt` only stands in when nothing else is known.
            let heartbeat = KnockDateFormat.date(from: session.lastSeenAt) ?? now
            let idleSince = AgentStatus.lastActivity(session, cases: cases) ?? heartbeat
            lastSeen = waiting.isEmpty
                ? "idle \(CaseTimes.compactDuration(now.timeIntervalSince(idleSince)))"
                : "seen \(ago(since: heartbeat, now: now))"
        }
        return SessionActivity(
            kind: kind, nowLine: line, needsYouCount: needsYou.count,
            waitingCount: waiting.count, lastSeenLabel: lastSeen
        )
    }

    /// The "now" rule. An ask that needs the human wins. Otherwise the latest
    /// reply decides: queued means the agent has not picked it up yet,
    /// delivered means it is working on it. No such reply: nothing to say.
    static func nowState(asks: [Case], now: Date) -> (Kind, String) {
        let needsYou = asks.filter { $0.status == .needsYou }
        if let ask = needsYou.max(by: { $0.createdAt < $1.createdAt }) {
            return (.needsYou, "Waiting on you: \(ask.rowTitle)")
        }
        let replied = asks.compactMap { ask -> (Date, ReplyStatus, String)? in
            guard ask.status == .waitingOnAgent,
                  let state = ask.latestReplyState, state == .queued || state == .delivered,
                  let at = ask.latestReplyAt.flatMap(KnockDateFormat.date(from:)) else { return nil }
            return (at, state, ask.isFeedbackReply ? "feedback" : "reply")
        }
        if let latest = replied.max(by: { $0.0 < $1.0 }) {
            let t = CaseTimes.compactDuration(now.timeIntervalSince(latest.0))
            return latest.1 == .queued
                ? (.waitingForPickup, "Sent \(t) ago · waiting for pickup")
                : (.working, "Working · \(t) since your \(latest.2)")
        }
        return (.idle, "Connected, nothing to decide")
    }

    /// "just now" under 5 s, else "20s ago".
    static func ago(since date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        return seconds < 5 ? "just now" : "\(CaseTimes.compactDuration(seconds)) ago"
    }

    /// "<project> · <branch>", or just the project when there is no branch.
    static func title(_ session: SessionInfo) -> String {
        guard let branch = session.branch, !branch.isEmpty else { return session.project }
        return "\(session.project) · \(branch)"
    }

    /// "up 2h 14m", the session's age.
    static func uptime(_ session: SessionInfo, now: Date) -> String {
        let at = KnockDateFormat.date(from: session.connectedAt) ?? now
        return "up \(CaseTimes.compactDuration(now.timeIntervalSince(at)))"
    }

    /// Asks created on the same calendar day as `now`, newest first.
    static func asksToday(_ asks: [Case], now: Date, calendar: Calendar = .current) -> [Case] {
        asks.filter {
            guard let at = KnockDateFormat.date(from: $0.createdAt) else { return false }
            return calendar.isDate(at, inSameDayAs: now)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }
}

/// The queue filter a session's "Show its asks in the list" sets (HAIL-59):
/// only that session's task shows, until cleared.
struct SessionFilter: Equatable {
    let taskId: String
    /// "<project> · <branch>", for the "Showing ... · Clear" chip.
    let label: String

    func apply(_ cases: [Case]) -> [Case] {
        cases.filter { $0.taskId == taskId }
    }
}

extension SessionActivity {
    /// "N closed in the last hour": sessions that are no longer live and were
    /// last seen within the hour.
    static func closedInLastHour(_ sessions: [SessionInfo], now: Date) -> Int {
        sessions.filter { session in
            guard session.state != .live, let seen = KnockDateFormat.date(from: session.lastSeenAt) else { return false }
            return now.timeIntervalSince(seen) <= 3600
        }.count
    }
}

/// One row of the detail's "ITS ASKS TODAY" list (HAIL-69).
struct SessionAskRow: Equatable, Identifiable {
    let ask: Case
    /// The same status the queue and the pixel grid use (`AgentStatus.forCase`).
    let status: AgentStatus
    /// True for asks that moved to the queue's Answered group (HAIL-64).
    let isAnswered: Bool
    var id: String { ask.id }

    /// "Needs you", "Not picked up yet", "Working", "Writing", or "Answered".
    var stateLine: String {
        if isAnswered { return "Answered" }
        switch status {
        case .needsYou: return "Needs you"
        case .waitingForPickup: return "Not picked up yet"
        case .working: return "Working"
        case .writingToYou: return "Writing"
        case .connected, .closed: return "Session closed"
        }
    }
}

extension SessionActivity {
    /// The detail's ask list: today's asks, newest first, open ones first and
    /// the answered ones after them (under the "Answered" divider).
    struct AskGroups: Equatable {
        let open: [SessionAskRow]
        let answered: [SessionAskRow]
        var total: Int { open.count + answered.count }
    }

    /// `open` is the session's needs-you and still-waiting asks, `answered`
    /// its asks in the Answered group (`AnswerGrouping.split`).
    static func askGroups(
        open: [Case], answered: [Case], now: Date, calendar: Calendar = .current
    ) -> AskGroups {
        AskGroups(
            open: asksToday(open, now: now, calendar: calendar).map {
                SessionAskRow(ask: $0, status: AgentStatus.forCase($0), isAnswered: false)
            },
            answered: asksToday(answered, now: now, calendar: calendar).map {
                SessionAskRow(ask: $0, status: AgentStatus.forCase($0), isAnswered: true)
            }
        )
    }
}

/// Size rules of the sessions panel (HAIL-69). Pure, so the height cap is
/// testable without a window.
enum SessionsPanelLayout {
    /// The footer plus the gap the panel floats above it.
    static let footerReserve: CGFloat = 52
    static let topMargin: CGFloat = 12
    static let hardMaxHeight: CGFloat = 520
    /// Rows the detail's ask list shows before it scrolls.
    static let maxVisibleAskRows = 8
    static let askRowHeight: CGFloat = 46

    /// Window height minus the footer and a 12 pt top margin, never above 520.
    static func maxHeight(windowHeight: CGFloat) -> CGFloat {
        max(0, min(hardMaxHeight, windowHeight - footerReserve - topMargin))
    }

    /// Height of the ask list's viewport: its rows, at most 8 rows' worth.
    static func askListHeight(rowCount: Int, dividerCount: Int) -> CGFloat {
        let rows = min(rowCount, maxVisibleAskRows)
        return CGFloat(rows) * askRowHeight + (dividerCount > 0 ? CGFloat(dividerCount) * dividerHeight : 0)
    }

    static let dividerHeight: CGFloat = 26
}
