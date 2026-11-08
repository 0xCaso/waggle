import Foundation
import SwiftUI

/// What the Sessions popover shows from a session's context (HAIL-72). Pure
/// functions, so the row ladder and the detail's hidden sections are testable
/// without a window. The daemon already sends plain one-line text.
enum SessionContextDisplay {
    /// Line 3 of a popover row.
    enum RowLine: Equatable {
        /// Today's status line and styling: an ask needs you, a reply waits for
        /// pickup, or the session has no context.
        case status
        /// "<done> of <total> · <current step>" with a thin progress bar.
        case plan(done: Int, total: Int, text: String)
        /// The last action in plain words.
        case lastAction(String)
    }

    /// True when an ask needs the human or a reply waits for pickup. That
    /// status line wins over any context.
    static func statusWins(_ activity: SessionActivity) -> Bool {
        activity.kind == .needsYou || activity.kind == .waitingForPickup
    }

    /// The ladder: needs-you and waiting-for-pickup win, then the plan, then
    /// the last action, else today's line.
    static func rowLine(activity: SessionActivity, context: SessionContext?) -> RowLine {
        if statusWins(activity) { return .status }
        if let plan = context?.plan, plan.total > 0 {
            let done = min(max(plan.done, 0), plan.total)
            let head = "\(done) of \(plan.total)"
            let step = nonEmpty(plan.current)
            return .plan(done: done, total: plan.total, text: step.map { "\(head) · \($0)" } ?? head)
        }
        if let action = plainAction(context?.lastAction) { return .lastAction(action) }
        return .status
    }

    /// Line 2 of a row: the session title (WAG-279), when there is one.
    static func rowTitle(_ session: SessionInfo) -> String? {
        SessionTitle.pick(session)
    }

    /// What a session is about (HAIL-119, WAG-279): the title the agent sent, else Claude's own title,
    /// else its goal (the first prompt), else the project name. Never the agent's last message
    /// (`said`): that is a status update.
    static func summary(_ session: SessionInfo) -> String {
        SessionTitle.pick(session) ?? session.project
    }

    /// A last action older than this is not "doing now" any more (HAIL-124).
    static let doingNowMaxAge: TimeInterval = 600

    /// "Ran swift test · 20s ago": the last action with its age, or nil when there is none, its
    /// time is unknown, or it is older than 10 minutes (HAIL-124).
    static func doingNow(_ context: SessionContext?, now: Date) -> String? {
        guard let action = lastActionText(context),
              let at = context?.lastActionAt.flatMap(KnockDateFormat.date(from:)) else { return nil }
        let age = now.timeIntervalSince(at)
        guard age <= doingNowMaxAge else { return nil }
        return "\(action) · \(SessionActivity.ago(since: at, now: now))"
    }

    /// The last action alone, without its age (HAIL-232: Home shows the age as a pill).
    static func lastActionText(_ context: SessionContext?) -> String? { plainAction(context?.lastAction) }

    /// The last action in plain words (WAG-302). A command that is more than a short program name and
    /// subcommands ("Ran (perl", "Ran ls | grep $X") reads "Ran a command". Any other action with code
    /// marks or a path in it is dropped.
    static func plainAction(_ raw: String?) -> String? {
        guard let action = nonEmpty(raw)?.trimmingCharacters(in: .whitespacesAndNewlines), !action.isEmpty else { return nil }
        if action.hasPrefix("Ran ") {
            let words = action.dropFirst(4).split(whereSeparator: \.isWhitespace)
            let clean = !words.isEmpty && words.count <= 3 && words.allSatisfy {
                $0.range(of: #"^[A-Za-z][A-Za-z0-9._:-]*$"#, options: .regularExpression) != nil
            }
            return clean ? action : "Ran a command"
        }
        let marks = CharacterSet(charactersIn: "()[]{}|<>$`;&\\/=")
        return action.rangeOfCharacter(from: marks) == nil ? action : nil
    }

    /// The detail's header: the session title as the main title when present.
    static func headerTitle(session: SessionInfo) -> String {
        rowTitle(session) ?? SessionActivity.title(session)
    }

    /// "project · branch · runtime · seen …" under a titled header. Without a
    /// title it is today's "runtime · up … · seen …".
    static func headerSubtitle(session: SessionInfo, now: Date) -> String {
        let seenAt = KnockDateFormat.date(from: session.lastSeenAt) ?? now
        let seen = "seen \(SessionActivity.ago(since: seenAt, now: now))"
        if rowTitle(session) != nil {
            return "\(SessionActivity.title(session)) · \(session.runtimeLabel) · \(seen)"
        }
        return "\(session.runtimeLabel) · \(SessionActivity.uptime(session, now: now)) · \(seen)"
    }

    /// The detail's sections. A section with no data is nil or empty, and the
    /// view does not draw it.
    struct Sections: Equatable {
        /// GOAL: the first real user prompt.
        let goal: String?
        /// NOW, first line: the first sentence of the agent's last message.
        let said: String?
        /// NOW, second line: "Last: <action> · <time>".
        let lastLine: String?
        /// RECENT: the last 3 actions, newest first.
        let recent: [String]
        /// CHANGES: "N files · +a −r · <last commit>" or "Clean · <last commit>".
        let changes: String?

        var hasNowContext: Bool { said != nil || lastLine != nil }
    }

    static func sections(session: SessionInfo, now: Date) -> Sections {
        let context = session.context
        let lastLine: String? = plainAction(context?.lastAction).map { action in
            let at = context?.lastActionAt.flatMap(KnockDateFormat.date(from:))
                ?? KnockDateFormat.date(from: session.lastSeenAt)
            return "Last: \(action) · \(at.map { SessionActivity.ago(since: $0, now: now) } ?? "just now")"
        }
        return Sections(
            goal: nonEmpty(context?.goal),
            said: nonEmpty(context?.said),
            lastLine: lastLine,
            recent: Array((context?.recent ?? []).filter { !$0.isEmpty }.suffix(3).reversed()),
            changes: context?.changes.flatMap(changesLine)
        )
    }

    /// "3 files · +120 −4 · Fix the thing", "Clean · Fix the thing", or "Clean".
    static func changesLine(_ changes: SessionContext.Changes) -> String? {
        let commit = nonEmpty(changes.lastCommit)
        if changes.clean || changes.files == 0 {
            return commit.map { "Clean · \($0)" } ?? "Clean"
        }
        let files = "\(changes.files) \(changes.files == 1 ? "file" : "files")"
        return [files, "+\(changes.added) \u{2212}\(changes.removed)", commit].compactMap { $0 }.joined(separator: " · ")
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}

/// Alignment of a popover row's parts (HAIL-72): the pixel grid and the time
/// label sit at the top, level with the first text line, not centred.
enum SessionRowLayout {
    static let rowAlignment: VerticalAlignment = .top
    static let trailingAlignment: HorizontalAlignment = .trailing
    /// Half the gap between the 12.5 pt title line (about 15 pt tall) and the
    /// 4 pt-cell grid (13.5 pt), so the grid centres on the first line.
    static let gridTopInset: CGFloat = 1
    /// The right-hand time label, level with the first line.
    static let timeTopInset: CGFloat = 1
    static let progressBarHeight: CGFloat = 3
}
