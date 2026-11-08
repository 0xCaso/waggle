import Foundation

/// The ask pane's split (HAIL-71, Pen `r01vFQ`): the decision on the left, the
/// conversation on the right. It applies only to an ask with a thread.
enum ConversationSplit {
    /// Width of the right column.
    static let columnWidth: CGFloat = 380
    /// Below this pane width the column slides over the decision instead of sitting beside it.
    /// 800, not 900: on a 1512 pt laptop screen the pane beside the queue is
    /// about 876 pt, and the split must show there (the left column keeps
    /// about 420 pt).
    static let collapseBelow: CGFloat = 800

    /// `KNOCK_SPLIT_COLLAPSE_BELOW=<points>` (HAIL-71 evidence hook): the screen is too
    /// small for an 800 pt pane beside the queue, so the harness lowers the threshold
    /// to capture the wide layout. Unset in normal use.
    static func isCollapsed(
        paneWidth: CGFloat, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let threshold = environment["KNOCK_SPLIT_COLLAPSE_BELOW"].flatMap(Double.init).map { CGFloat($0) } ?? collapseBelow
        return paneWidth < threshold
    }

    /// Whether the ask has a conversation column at all (HAIL-91). It is the same rule that builds
    /// the column: `CaseDetail.threadModel` is nil until you send a reply, so a single round (the
    /// ask alone) has no column, no header segment, no fold icon, no rail and ⌘] does nothing.
    /// A reply (the second round) makes the column appear; the saved fold then applies.
    static func hasColumn(thread: ThreadModel?) -> Bool { thread != nil }

    /// Whether the column is on screen (WAG-299): the case has a thread, the operator opened it for
    /// this case, and the sides are not both folded. Every case starts closed.
    static func isShown(hasThread: Bool, isOpen: Bool, isBothFolded: Bool) -> Bool {
        hasThread && isOpen && !isBothFolded
    }
}

/// The words of the conversation column. Pure, so they are unit-tested.
enum ConversationCopy {
    /// "CONVERSATION · 2 ROUNDS": the first ask is round 1, each reply starts the next.
    static func title(_ model: ThreadModel) -> String {
        "CONVERSATION · \(model.roundCount) ROUND\(model.roundCount == 1 ? "" : "S")"
    }

    /// "2": the round count beside the header icon (WAG-299).
    static func roundBadge(_ count: Int) -> String { "\(count)" }

    /// The header icon's tooltip.
    static let iconHelp = "Conversation (⌘ ])"

    /// "CLAUDE CODE · 21:10".
    static func askedHeader(_ asked: ThreadStep.Asked, runtime: String, timeZone: TimeZone = .current) -> String {
        "\(runtime.uppercased()) · \(ThreadCopy.clock(asked.at, timeZone: timeZone))"
    }

    /// "CLAUDE CODE · 21:24 · v2".
    static func updatedHeader(_ updated: ThreadStep.Updated, runtime: String, timeZone: TimeZone = .current) -> String {
        var parts = [runtime.uppercased(), ThreadCopy.clock(updated.at, timeZone: timeZone)]
        if let revision = updated.revision { parts.append("v\(revision.n)") }
        return parts.joined(separator: " · ")
    }

    /// "YOU · 21:23 · 1 comment on v1".
    static func repliedHeader(_ replied: ThreadStep.Replied, timeZone: TimeZone = .current) -> String {
        (["YOU", ThreadCopy.clock(replied.at, timeZone: timeZone)] + [replied.meta].compactMap { $0 }).joined(separator: " · ")
    }

    /// "✓ picked up 21:23 · worked 8s".
    static func pickedUpLine(_ picked: ThreadStep.PickedUp, timeZone: TimeZone = .current) -> String {
        "✓ picked up " + ThreadCopy.clock(picked.at, timeZone: timeZone) + (picked.worked.map { " · " + ThreadCopy.worked($0) } ?? "")
    }

    /// "Your turn": the column is narrow, so the hint after the colon stays in the composer.
    static func turnLabel(_ turn: ThreadTurn) -> String {
        turn.status == .needsYou ? String(turn.label.prefix { $0 != ":" }) : turn.label
    }

    /// "v1 · see in review": the link to the version before the update's own.
    static func priorVersionLink(_ updated: ThreadStep.Updated) -> String? {
        guard let revision = updated.revision, revision.isLatest, let prior = revision.prior else { return nil }
        return "v\(prior) · see in review"
    }
}

extension ThreadModel {
    /// Rounds so far: the first ask, plus one for each reply of yours.
    var roundCount: Int {
        1 + steps.filter { if case .replied = $0 { true } else { false } }.count
    }
}
