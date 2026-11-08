import Foundation

/// An ask that came back after you answered it (HAIL-67): the agent sent a
/// `knock_update` and the case returned to Needs you. The queue row, the ask
/// pane thread, the review window's ask column and the notification all read this, so
/// they say the same thing about why the ask is back.
struct CaseUpdateSummary: Equatable, Sendable {
    let at: Date
    /// The first ~140 characters of the newest agent message, on one line.
    let message: String
    /// The first line of that message: what the queue row and the notification show (WAG-337).
    let firstLine: String
    /// "v<N>" when a revision was added after your latest reply; `nil` otherwise.
    /// The row has no revision list, so this reads `revision_count` and
    /// `latest_revision_at` (HAIL-68): a revision made before the reply does not count.
    let revision: Int?
}

extension Case {
    /// Non-nil only while the update is the news: the case is in Needs you and
    /// the agent's newest message is later than your latest reply. Answering
    /// again moves the case out of Needs you, so this clears by itself.
    var pendingUpdate: CaseUpdateSummary? {
        guard status == .needsYou, (updateCount ?? 0) > 0,
              let updateAt = latestUpdateAt.flatMap(KnockDateFormat.date(from:)),
              let replyAt = latestReplyAtDate, updateAt > replyAt else { return nil }
        let message = (latestUpdateMessage ?? "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let revisions = revisionCount ?? 0
        let madeAfterReply = latestRevisionAt.flatMap(KnockDateFormat.date(from:)).map { $0 > replyAt } ?? false
        return CaseUpdateSummary(at: updateAt, message: message, firstLine: NoteText.firstLine(latestUpdateMessage), revision: revisions >= 2 && madeAfterReply ? revisions : nil)
    }

    /// The queue row's update label: "Updated · v3" (the time sits in the row header).
    var updateLabel: String? {
        guard let update = pendingUpdate else { return nil }
        return update.revision.map { "Updated · v\($0)" } ?? "Updated"
    }
}

/// The agent's latest message when it sent a message-only update after your reply (WAG-337): no new
/// options, no new revision, not done. The protocol returns such a case to Needs you, so the page shows
/// the message first and folds the round it answers.
struct MessageOnlyUpdate: Equatable, Sendable {
    let at: Date
    /// The whole message, trimmed.
    let message: String
    /// True when the last line asks something. The earlier options then stay live.
    let waitsForAnswer: Bool
    /// True when the round it follows stays live: the message asks something, or it answers a talk
    /// reply (discuss or more detail, WAG-393), so the human can still pick.
    let staysLive: Bool

    /// The same note with the agent's full text from the case detail (WAG-393). `latest_update_message`
    /// is a preview the daemon cuts. Keeps the preview when the detail holds no newer agent message.
    func fullText(from messages: [Message], after replyAt: Date?) -> MessageOnlyUpdate {
        let newest = messages
            .filter { $0.role == .agent }
            .compactMap { m in KnockDateFormat.date(from: m.createdAt).map { (m, $0) } }
            .filter { replyAt == nil || $0.1 > replyAt! }
            .max { $0.1 < $1.1 }
        let text = newest?.0.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return self }
        return MessageOnlyUpdate(at: at, message: text, waitsForAnswer: NoteText.asksSomething(text), staysLive: staysLive || NoteText.asksSomething(text))
    }
}

enum NoteText {
    /// The first non-empty line, with the whitespace inside it folded.
    static func firstLine(_ text: String?) -> String {
        let line = (text ?? "").components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The agent still waits for an answer when its last line ends with a question mark.
    static func asksSomething(_ text: String) -> Bool {
        let last = text.components(separatedBy: .newlines)
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return last.trimmingCharacters(in: .whitespaces).hasSuffix("?")
    }
}

extension Case {
    var messageOnlyUpdate: MessageOnlyUpdate? {
        guard let update = pendingUpdate, !isDone else { return nil }
        let text = (latestUpdateMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let replyAt = latestReplyAtDate else { return nil }
        // An update with options made the newest set after the reply; one with a revision made a revision.
        if let optionsAt = optionsUpdatedAt.flatMap(KnockDateFormat.date(from:)), optionsAt > replyAt { return nil }
        if update.revision != nil { return nil }
        if (revisionCount ?? 0) >= 2, let rev = latestRevisionAt.flatMap(KnockDateFormat.date(from:)), rev > replyAt { return nil }
        let asks = NoteText.asksSomething(text)
        return MessageOnlyUpdate(at: update.at, message: text, waitsForAnswer: asks, staysLive: asks || isTalkingItOver)
    }

    /// True while a message-only update has settled the earlier round: its options are read-only.
    var earlierRoundIsReadOnly: Bool {
        // A progress note folds the options too (WAG-377). The human can still type a free reply.
        if workingNoteText != nil { return true }
        guard let note = messageOnlyUpdate else { return false }
        return !note.staysLive
    }
}
