import SwiftUI

/// The words for an agent session that a host closed while an ask or an answer was open (WAG-258,
/// waggle-releases issue 3). Plain and friendly, no em-dashes.
enum SessionClosedCopy {
    /// The status line's longer words while the ask still needs you and its session closed.
    static let notice = "This agent's session has closed. Your answer is saved and reaches the agent when you next message it."
    /// The small mark on a queue row.
    static let mark = "Session closed"
    /// The reply state once the human answered a closed session.
    static let savedTitle = "Saved · delivers when the agent's session resumes"
    static let savedNote = "Your answer is saved. It reaches the agent when you next message it, or paste the copied answer in the agent's chat."
    /// The reply state once the session is back: the agent gets the saved answer at its next check.
    static let resumedTitle = "Saved · the agent gets it at its next check"
    static let resumedNote = "The agent's session is back. Your answer goes to it the next time it checks Waggle."

    /// The status line's words for a closed session, from the real order of events.
    static func stripHeadline(for item: Case) -> String {
        if item.latestReplyState == .delivered { return "The session closed after it read your reply" }
        return item.closedBeforeReply
            ? "The session closed before you replied"
            : "The session closed before it read your reply"
    }
}

extension Case {
    /// An open ask whose session ended before the human answered.
    var sessionClosedBeforeAnswer: Bool {
        status == .needsYou && sessionState == .ended && !isDone
    }

    /// The session ended before the reply was written (true), or after it (false). Without both times
    /// the answer is false: the older copy then applies.
    var closedBeforeReply: Bool {
        guard let ended = sessionEndedAtDate, let replied = latestReplyAtDate else { return false }
        return replied >= ended
    }

    /// True when the queue row shows the "Session closed" mark: an open ask on an ended session, an
    /// answer saved for an ended session, or any failed reply (WAG-258 AC 1 and 5).
    var showsSessionClosedMark: Bool {
        guard status != .resolved, !isDone else { return false }
        switch status {
        case .needsYou: return sessionState == .ended
        case .waitingOnAgent: return latestReplyState == .failed || isStaleQueuedReply
        case .resolved: return false
        }
    }
}

/// The words of the agent's status on the request page's status line (HAIL-66, C10). Pure, so the copy is
/// unit-tested. Plain and friendly, no em-dashes.
enum AgentStatusCopy {
    /// The status line's words; nil for a status that has none (an ask that
    /// still needs you, a connected session).
    static func headline(status: AgentStatus, runtime: String, item: Case?) -> String? {
        if status == .closed, let item { return SessionClosedCopy.stripHeadline(for: item) }
        if status == .working, item?.isFeedbackReply == true { return "\(runtime) is working on your feedback" }
        return headline(status: status, runtime: runtime)
    }

    static func headline(status: AgentStatus, runtime: String) -> String? {
        switch status {
        case .working: "\(runtime) is working on your reply"
        case .waitingForPickup: "\(runtime) has not picked up your reply yet"
        case .writingToYou: "\(runtime) is writing the detail you asked for"
        case .closed: "The session closed before it read your reply"
        case .needsYou, .connected: nil
        }
    }

    /// "16:05" in the given zone.
    static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// The settled line of an answered ask (HAIL-104): no timer, no live status.
    static func settledLine(pickedUpAt: Date?, timeZone: TimeZone = .current) -> String {
        guard let pickedUpAt else { return "Not picked up" }
        return "Picked up at \(clock(pickedUpAt, timeZone: timeZone))"
    }

    /// "Followed up: <title>", the link under the settled line.
    static func followUpLine(_ followUp: AnswerGrouping.Settled.FollowUp) -> String {
        "Followed up: \(AgentMarkdown.singleLine(followUp.title))"
    }

    /// The small text after the status line's words: "read at 16:05" once the agent
    /// read the reply. Nothing while it has not.
    static func readLine(readAt: Date?, afterNudge: Bool = false, timeZone: TimeZone = .current) -> String? {
        guard let readAt else { return nil }
        let read = "read at \(clock(readAt, timeZone: timeZone))"
        return afterNudge ? "\(Nudge.wokeReadPrefix) · \(read)" : read
    }
}

/// The settled status of an answered ask (HAIL-104): a still grid, "Picked up at 21:05" and,
/// when a follow-up ask exists, a link that opens it. No timer, no shimmer.
struct SettledAnswerLine: View {
    let settled: AnswerGrouping.Settled
    var onOpenCase: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentStatusLine(
                status: .closed, cell: 5, label: AgentStatusCopy.settledLine(pickedUpAt: settled.pickedUpAt),
                since: nil, labelFont: .sans(12.5), spacing: 10)
            if let followUp = settled.followUp {
                Button { onOpenCase(followUp.id) } label: {
                    Text(AgentStatusCopy.followUpLine(followUp))
                        .knockTextStyle(Theme.Typography.recommendLine12w400)
                        .foregroundColor(Theme.Colors.ds)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain).pointerCursor()
            }
        }
    }
}
