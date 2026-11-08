import Foundation

/// One thread of team comments (WAG-394): a root with its replies, oldest first.
struct CommentThread: Equatable, Identifiable {
    let root: SharedComment
    let replies: [SharedComment]

    var id: String { root.id }
    var isResolved: Bool { root.resolvedAt != nil }
    var hasUnread: Bool { root.unread || replies.contains { $0.unread } }
}

enum CommentThreads {
    /// Groups the flat list. A reply whose root is missing shows as its own thread, so nothing is lost.
    static func build(_ comments: [SharedComment]) -> [CommentThread] {
        let rootIds = Set(comments.filter { $0.parentId == nil }.map(\.id))
        var repliesByRoot: [String: [SharedComment]] = [:]
        var roots: [SharedComment] = []
        for c in comments {
            if let parent = c.parentId, rootIds.contains(parent) {
                repliesByRoot[parent, default: []].append(c)
            } else {
                roots.append(c)
            }
        }
        return roots.map { CommentThread(root: $0, replies: repliesByRoot[$0.id] ?? []) }
    }

    /// "Resolved · Ada: first line of the comment" for a folded thread.
    static func foldedLine(_ thread: CommentThread) -> String {
        "Resolved \u{00B7} \(SharedCommentText.name(thread.root)): \(SharedCommentText.firstLine(thread.root.body))"
    }

    /// The label above a reply. The agent shows as "Agent", the owner as "You".
    static func author(_ c: SharedComment) -> String {
        switch c.authorKind {
        case "agent": "Agent"
        case "owner": "You"
        default: SharedCommentText.name(c)
        }
    }

    /// A reply needs a body of 1 to 4000 characters.
    static let maxReply = 4000
    static func canSend(_ text: String, busy: Bool, commentsClosed: Bool) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !busy && !commentsClosed && !t.isEmpty && t.count <= maxReply
    }
}

/// Words for the notification and the sheet (WAG-394).
enum TeamCommentCopy {
    static let closedLine = "Comments are closed."
    static let newLinkLine = "This makes a new link. The old link stays off."
    static func closeTitle(closed: Bool) -> String { closed ? "Open comments" : "Close comments" }
    /// The line under the audience choice when the case was shared before and is not now.
    static func newLinkNote(shared: Bool, sharedBefore: Bool) -> String? { !shared && sharedBefore ? newLinkLine : nil }
}

extension NotificationBuilder {
    /// "<name> commented on <case title>", the first line of the comment as the body, one thread per case.
    /// `showsText` is the Settings toggle "Show the decision in the notification" (as for an ask): off posts only
    /// a fixed title and no comment words, so a screen-shared notification never leaks what the case is about.
    static func commentContent(
        for item: TeamCommentNotice, showsText: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> NotificationContent {
        let name = item.authorName.trimmingCharacters(in: .whitespaces)
        let title = showsText ? "\(name.isEmpty ? "Someone" : name) commented on \(item.caseTitle)" : "Your team commented on a case"
        let isTestCopy = TestCopyEnvironment.isActive(environment: environment, bundleIdentifier: bundleIdentifier)
        return NotificationContent(
            identifier: "case.\(item.caseId).comment.\(item.commentId)",
            caseId: item.caseId,
            title: isTestCopy ? "[test] \(title)" : title,
            subtitle: "",
            body: showsText ? SharedCommentText.firstLine(item.body) : "Open Waggle to read it.",
            threadId: item.caseId,
            opensComments: true
        )
    }
}

/// Unread marks and comment notifications for the app (WAG-394). The daemon does the work; this asks it
/// and passes on the answer. Closures keep it testable.
@MainActor
final class TeamCommentsFeed {
    private let unread: () async throws -> [UnreadCase]
    private let markSeenCall: (String) async throws -> [UnreadCase]
    private let take: () async throws -> [TeamCommentNotice]
    private let gate: () -> Bool
    private let notify: (NotificationContent) -> Void
    private let onUnread: ([String: Int]) -> Void
    private let environment: [String: String]
    private let bundleIdentifier: String?

    init(
        unread: @escaping () async throws -> [UnreadCase],
        markSeen: @escaping (String) async throws -> [UnreadCase],
        take: @escaping () async throws -> [TeamCommentNotice],
        gate: @escaping () -> Bool, notify: @escaping (NotificationContent) -> Void,
        onUnread: @escaping ([String: Int]) -> Void,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        self.unread = unread
        markSeenCall = markSeen
        self.take = take
        self.gate = gate
        self.notify = notify
        self.onUnread = onUnread
        self.environment = environment
        self.bundleIdentifier = bundleIdentifier
    }

    static func map(_ cases: [UnreadCase]) -> [String: Int] {
        Dictionary(cases.filter { $0.count > 0 }.map { ($0.caseId, $0.count) }, uniquingKeysWith: { $1 })
    }

    func refreshUnread() async {
        if let cases = try? await unread() { onUnread(Self.map(cases)) }
    }

    /// Opening a case clears its mark. The daemon answers with the marks that are left.
    func markSeen(caseId: String) async {
        if let cases = try? await markSeenCall(caseId) { onUnread(Self.map(cases)) }
    }

    /// Takes the new comments the daemon has not announced and posts one notification each. With "Show the
    /// decision in the notification" off the notification has fixed words and no comment text.
    func announce() async {
        guard let items = try? await take() else { return }
        for item in items {
            notify(NotificationBuilder.commentContent(for: item, showsText: gate(), environment: environment, bundleIdentifier: bundleIdentifier))
        }
    }
}
