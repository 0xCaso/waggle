import Foundation

/// WAG-397: the one Comments tab. Your notes to the agent and the team thread from the shared page sit in one
/// list, each with a label. The pure parts live here: the order, the labels, the words, and the target of the
/// composer.
enum MergedComments {
    /// One entry of the list: a note to the agent, or a thread from the page.
    enum Entry: Identifiable, Equatable {
        case local(CommentRow)
        case thread(CommentThread)

        var id: String {
            switch self {
            case .local(let row): "local-\(row.id)"
            case .thread(let thread): "thread-\(thread.id)"
            }
        }
    }

    /// Team threads first, oldest first (by the time of the root comment; the daemon's order breaks a tie).
    /// Then your notes to the agent, in number order: a note has no time and waits for Send, so it sits last.
    static func entries(local: [CommentRow], threads: [CommentThread]) -> [Entry] {
        let ordered = threads.enumerated().sorted {
            ($0.element.root.createdAt, $0.offset) < ($1.element.root.createdAt, $1.offset)
        }.map(\.element)
        return ordered.map(Entry.thread) + local.sorted { $0.number < $1.number }.map(Entry.local)
    }

    static let youLabel = "You"
    static let teamLabel = "Team"
    static let agentLabel = "Agent"
    static let ownerOnPageLabel = "You \u{00B7} on the page"

    /// The label of one comment from the page: Team (member or guest), Agent, or "You · on the page" (owner).
    static func label(_ c: SharedComment) -> String {
        switch c.authorKind {
        case "agent": agentLabel
        case "owner": ownerOnPageLabel
        default: teamLabel
        }
    }

    /// A member or a guest wrote it: the comments the count line counts.
    static func isTeam(_ c: SharedComment) -> Bool { c.authorKind != "agent" && c.authorKind != "owner" }

    /// "3 team comments, 1 new" for the Decision tab, or nil when the team wrote nothing.
    static func countLine(_ comments: [SharedComment]) -> String? {
        let team = comments.filter(isTeam)
        guard !team.isEmpty else { return nil }
        let fresh = team.filter(\.unread).count
        let base = "\(team.count) team \(team.count == 1 ? "comment" : "comments")"
        return fresh > 0 ? "\(base), \(fresh) new" : base
    }

    static let sharedEmptyLine = "No comments yet. Your team comments on the page; you can write to the agent or on the page below."

    /// Labels show once the case is shared or has team comments. Else the list is the same as before.
    static func showsLabels(isShared: Bool, threads: [CommentThread]) -> Bool { isShared || !threads.isEmpty }

    /// Where the composer sends the text.
    enum Target: Equatable { case agent, page }

    static let agentPlaceholder = "Write to the agent. Your team does not see it."
    static let pagePlaceholder = "Write on the page. Your team sees it."

    static func placeholder(_ target: Target) -> String { target == .agent ? agentPlaceholder : pagePlaceholder }

    static func title(_ target: Target) -> String { target == .agent ? "To the agent" : "On the page" }

    /// The switch shows only while the case is shared and Sharing is on. Else the target is the agent.
    static func effectiveTarget(_ chosen: Target, canWriteOnPage: Bool) -> Target { canWriteOnPage ? chosen : .agent }
}
