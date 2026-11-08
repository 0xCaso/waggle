import Foundation

/// Strips an agent's own letter/number prefix off an option label for
/// display (HAIL-54: Knock numbers every option itself with the key badge -
/// a label pre-numbered by the agent, like `"A · Compact"` or `"2) Detailed"`,
/// would otherwise read as double-numbered). The full label - prefix and all
/// - is untouched everywhere else: `Option.label` is what is sent, only the
/// row's displayed text runs through this.
enum OptionLabelFormatting {
    /// One or two letters/digits, then `·`, `.`, `)` or `:`, then at least one
    /// space - covers every example the contract gives ("A · ", "A. ",
    /// "A) ", "B: ", "1. ", "2) ") without matching ordinary text that merely
    /// starts with a digit, like "3 pack bundle" (no separator follows the
    /// "3", so nothing strips).
    static func displayLabel(_ raw: String) -> String {
        guard let match = raw.firstMatch(of: /^([A-Za-z]|[0-9]{1,2})\s*[·.):]\s+/) else { return raw }
        return String(raw[match.range.upperBound...])
    }

    /// The Decision section's full text for an option (operator, 30 Sep: "drop
    /// the repeated 'Title:' at the start of the full text"): `displayLabel`,
    /// minus a leading copy of the option's own title followed by ":" (case
    /// and spacing ignored), with the next letter capitalised. Anything else
    /// is left as written.
    static func decisionBody(label raw: String, title: String) -> String {
        let text = displayLabel(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let head = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty, text.lowercased().hasPrefix(head.lowercased()) else { return text }
        let rest = text.dropFirst(head.count).drop(while: { $0 == " " })
        guard rest.first == ":" else { return text }
        let body = rest.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = body.first else { return text }
        return first.uppercased() + body.dropFirst()
    }

    /// The longest a derived clause or sentence title runs (HAIL-99). A longer
    /// one is not cut: the whole label is the title instead.
    static let maxDerivedTitleLength = 60

    /// The most characters an answer box row shows for a title (about three
    /// wrapped lines) before `cutAtWord` shortens it.
    static let maxRowTitleLength = 150

    /// Where a clause ends (HAIL-99).
    private static let clauseBreaks = [";", " — ", " – ", " - ", " ("]

    /// A short title for an option with no agent title (HAIL-85, HAIL-99), in
    /// this order: the text before the first ":" when that is 1 to 6 words;
    /// the first clause (before ";", a dash or " (") when at most 60
    /// characters; the first sentence when at most 60 characters; else the
    /// whole label. Never cut, never "…". The agent's prefix is stripped
    /// first, as `displayLabel` does.
    static func derivedTitle(fromLabel label: String) -> String {
        let raw = displayLabel(label).trimmingCharacters(in: .whitespacesAndNewlines)
        let text = raw.split(whereSeparator: \.isNewline).joined(separator: " ")
        if let colon = text.firstIndex(of: ":") {
            let head = text[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let words = head.split(whereSeparator: \.isWhitespace).count
            if words >= 1, words <= 6 { return head }
        }
        if let clause = firstClause(of: text), !clause.isEmpty, clause.count <= maxDerivedTitleLength { return clause }
        let sentence = firstSentence(of: text)
        if sentence.count <= maxDerivedTitleLength { return sentence }
        return text
    }

    /// The text before the earliest clause break, trimmed of trailing commas
    /// and spaces; nil when there is no break.
    private static func firstClause(of text: String) -> String? {
        var end = text.endIndex
        for mark in clauseBreaks {
            if let range = text.range(of: mark), range.lowerBound < end { end = range.lowerBound }
        }
        guard end < text.endIndex else { return nil }
        return text[..<end].trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
    }

    /// Shortens `text` to at most `limit` characters at a word boundary and
    /// adds "…". Text within the limit is returned as is.
    static func cutAtWord(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit + 1))
        let words = head.split(separator: " ", omittingEmptySubsequences: true)
        // Drop the last word: it may be partial (the extra character shows whether it ended).
        let kept = head.last == " " ? words : words.dropLast()
        let cut = kept.isEmpty ? String(text.prefix(limit)) : kept.joined(separator: " ")
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.-")) + "…"
    }

    /// Up to and including the first ".", "!" or "?" that ends a sentence
    /// (followed by whitespace or the end of the text), else the whole text.
    private static func firstSentence(of text: String) -> String {
        var index = text.startIndex
        while index < text.endIndex {
            if ".!?".contains(text[index]) {
                let next = text.index(after: index)
                if next == text.endIndex || text[next].isWhitespace { return String(text[..<next]) }
            }
            index = text.index(after: index)
        }
        return text
    }
}

extension Option {
    /// What the answer box row, the queue row and the recommended block show:
    /// the agent's `title`, else one derived from `label`.
    var displayTitle: String {
        // A source marker in the agent's text is for the request page's pills, never for a title (WAG-356).
        if let title = title.map(SourceMarkers.strip)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        return OptionLabelFormatting.derivedTitle(fromLabel: SourceMarkers.strip(label))
    }
}
