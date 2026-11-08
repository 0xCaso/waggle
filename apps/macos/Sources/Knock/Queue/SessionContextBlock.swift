import SwiftUI

/// Where the session stands, shown above an ask's RECOMMENDED block (HAIL-102): a session line
/// and the session's earlier asks. It uses only what Knock already has: the session's context
/// summary (HAIL-72) and the other asks of the same task. The rules are pure, so selection
/// and folding are unit-tested without a window.
struct SessionContextBlock: Equatable {
    /// "This session: <summary> · 3rd ask · started 2h ago".
    struct Line: Equatable {
        let status: AgentStatus
        let summary: String
        /// "· 3rd ask · started 2h ago".
        let detail: String
        /// "2h": how long ago the session started (the context card's time column); nil when unknown.
        var startedAgo: String? = nil
        /// "Ran swift test · 20s ago"; nil when there is none or it is older than 10 minutes (HAIL-124).
        var doingNow: String? = nil
    }

    /// One earlier moment of the session: your answer, or the agent's update.
    struct Item: Equatable, Identifiable {
        enum Kind: Equatable { case answer, update }
        let caseId: String
        let kind: Kind
        let at: Date
        /// "You chose: <title>", "You answered: <text>" or "Update: <first line>".
        let text: String
        var id: String { "\(caseId)-\(kind == .answer ? "answer" : "update")" }
    }

    let line: Line?
    /// Oldest first, so the newest sits last.
    let earlier: [Item]
    /// This ask's place in the task: "3rd ask" is 3. nil when the block does not know it.
    var askNumber: Int? = nil

    var isEmpty: Bool { line == nil && earlier.isEmpty }

    /// Items shown while folded: the newest two.
    static let foldedCount = 2

    static func visible(_ items: [Item], showAll: Bool) -> [Item] {
        showAll ? items : Array(items.suffix(foldedCount))
    }

    /// "show all N", or `nil` when everything already shows.
    static func showAllLabel(total: Int, showAll: Bool) -> String? {
        total > foldedCount && !showAll ? "show all \(total)" : nil
    }

    // MARK: Selection

    /// The asks of the same task as `item`, other than itself: not dismissed, not withdrawn.
    static func siblings(of item: Case, in cases: [Case]) -> [Case] {
        guard !item.taskId.isEmpty else { return [] }
        return cases.filter {
            $0.id != item.id && $0.taskId == item.taskId && $0.dismissedAt == nil && $0.withdrawnAt == nil
        }
    }

    /// The earlier asks: created before `item`, with the id as the tie-break for one instant.
    static func earlierAsks(of item: Case, in cases: [Case]) -> [Case] {
        let at = item.createdAtDate ?? .distantFuture
        return siblings(of: item, in: cases).filter {
            let other = $0.createdAtDate ?? .distantPast
            return other < at || (other == at && $0.id < item.id)
        }
    }

    static func items(of item: Case, in cases: [Case]) -> [Item] {
        var out: [Item] = []
        for ask in earlierAsks(of: item, in: cases) {
            if let text = answerText(ask), let at = ask.latestReplyAtDate {
                out.append(Item(caseId: ask.id, kind: .answer, at: at, text: text))
            }
            if let text = updateText(ask), let at = ask.latestUpdateAt.flatMap(KnockDateFormat.date(from:)) {
                out.append(Item(caseId: ask.id, kind: .update, at: at, text: text))
            }
        }
        return out.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
    }

    /// "You chose: <option title>" for a picked option, else "You answered: <first line>".
    static func answerText(_ ask: Case) -> String? {
        guard ask.latestReplyAt != nil else { return nil }
        if !ask.latestReplyChoices.isEmpty {
            return "You chose: " + ask.repliedChoiceTitles.joined(separator: ", ")
        }
        if let words = ask.latestReplyWithChangesWords { return "You chose: \(words)" }
        if let choice = ask.latestReplyChoice, !choice.isEmpty {
            let title = ask.repliedOptions.first { $0.id == choice }?.displayTitle ?? choice
            return "You chose: \(title)"
        }
        guard let line = firstLine(ask.latestReplyMessage) else { return nil }
        return "You answered: \(line)"
    }

    static func updateText(_ ask: Case) -> String? {
        firstLine(ask.latestUpdateMessage).map { "Update: \($0)" }
    }

    /// The first non-empty line, with the common markdown markers taken out.
    static func firstLine(_ text: String?) -> String? {
        guard let text else { return nil }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw
                .replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "#>-* \t"))
            if !line.isEmpty { return line }
        }
        return nil
    }

    // MARK: The session line

    /// "1st", "2nd", "3rd", "4th", "11th", "21st".
    static func ordinal(_ n: Int) -> String {
        let tens = n % 100
        if (11...13).contains(tens) { return "\(n)th" }
        switch n % 10 {
        case 1: return "\(n)st"
        case 2: return "\(n)nd"
        case 3: return "\(n)rd"
        default: return "\(n)th"
        }
    }

    /// `nil` when the ask has no session. The summary is the title, goal or project (HAIL-119).
    static func line(
        item: Case, session: SessionInfo?, cases: [Case], now: Date
    ) -> Line? {
        guard let session else { return nil }
        let summary = SessionContextDisplay.summary(session)
        let number = earlierAsks(of: item, in: cases).count + 1
        var parts = ["· \(ordinal(number)) decision"]
        var startedAgo: String?
        if let started = KnockDateFormat.date(from: session.connectedAt) {
            startedAgo = CaseTimes.compactDuration(now.timeIntervalSince(started))
            parts.append("started \(SessionActivity.ago(since: started, now: now))")
        }
        return Line(
            status: AgentStatus.forSession(session, cases: cases), summary: summary,
            detail: parts.joined(separator: " · "), startedAgo: startedAgo,
            doingNow: SessionContextDisplay.doingNow(session.context, now: now))
    }

    static func make(item: Case, session: SessionInfo?, cases: [Case], now: Date) -> SessionContextBlock {
        SessionContextBlock(
            line: line(item: item, session: session, cases: cases, now: now),
            earlier: items(of: item, in: cases),
            askNumber: earlierAsks(of: item, in: cases).count + 1)
    }
}
