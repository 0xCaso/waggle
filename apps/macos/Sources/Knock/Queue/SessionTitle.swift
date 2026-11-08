import Foundation

/// WAG-279: the descriptive title of a session, shown in the sidebar and in the session detail instead of
/// the folder or worktree name. Pure, so the order and the filter are unit-tested without a window.
///
/// Order: 1) the title the agent sent (`session_title`), 2) Claude Code's own title (`context.title`),
/// 3) the first prompt (`context.goal`), shortened. When none is usable the caller shows the folder name.
/// A source that looks like a branch, a path, a worktree slug or an id is skipped (taste rule: never code).
enum SessionTitle {
    /// The goal is a whole prompt; as a title it is cut to this many characters.
    static let goalMaxLength = 48

    /// The title to show, or nil when the folder name should show.
    static func pick(_ session: SessionInfo) -> String? {
        let folder = ProjectName.display(project: session.project)
        let candidates = [
            session.sessionTitle,
            session.context?.title,
            session.context?.goal.map { shorten($0, to: goalMaxLength) },
        ]
        for case let raw? in candidates {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || looksLikeCode(text, session: session) { continue }
            // A title that only repeats the folder name adds nothing: the folder shows instead.
            if text.caseInsensitiveCompare(folder) == .orderedSame { continue }
            return text
        }
        return nil
    }

    /// The title of the session that owns `taskId`: a live one first, then the newest. Nil without one.
    static func forTask(_ taskId: String, in sessions: [SessionInfo]) -> String? {
        guard !taskId.isEmpty else { return nil }
        let owned = sessions.filter { $0.taskId == taskId }
        let ordered = owned.filter { $0.state == .live } + owned.filter { $0.state != .live }
        return ordered.lazy.compactMap(pick).first
    }

    /// True for a branch, a path, a worktree slug, a ticket id or a session id: text a person never
    /// wants as a title ("knock-waggle-xza23H", "WAG-275", "story/WAG-279", "/Users/me/app").
    static func looksLikeCode(_ text: String, session: SessionInfo? = nil) -> Bool {
        if text.contains("/") || text.contains("\\") || text.hasPrefix("~") { return true }
        if let session {
            if text.caseInsensitiveCompare(session.id) == .orderedSame { return true }
            if let branch = session.branch, text.caseInsensitiveCompare(branch) == .orderedSame { return true }
            if text.caseInsensitiveCompare(session.taskName) == .orderedSame, !text.contains(where: \.isWhitespace) {
                return true
            }
        }
        // More than one word is prose, whatever it contains.
        if text.contains(where: \.isWhitespace) { return false }
        // A ticket id: "WAG-275", "HAIL-171".
        if text.range(of: #"^[A-Za-z]{2,8}[-_]\d+$"#, options: .regularExpression) != nil { return true }
        // A slug or a branch: one token joined by dashes or underscores.
        if text.contains("-") || text.contains("_") { return true }
        // A hash or a uuid: hex digits only, with a digit in it.
        if text.count >= 7, text.allSatisfy(\.isHexDigit), text.contains(where: \.isNumber) { return true }
        // A generated id with letters and digits mixed in one token ("xza23H").
        if text.count >= 5, text.contains(where: \.isNumber), text.contains(where: \.isLetter) { return true }
        return false
    }

    /// The text cut at a word end to `limit` characters, with an ellipsis when it was cut.
    static func shorten(_ text: String, to limit: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > limit else { return t }
        let cut = String(t.prefix(limit - 1))
        let atWord = cut.range(of: #"\s+\S*$"#, options: .regularExpression).map { String(cut[..<$0.lowerBound]) } ?? cut
        return atWord.trimmingCharacters(in: .whitespaces) + "…"
    }
}
