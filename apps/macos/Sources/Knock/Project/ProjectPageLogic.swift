import Foundation

/// The words of the project page (WAG-260, Pen frame `dR3q0`). Pure, so the copy is unit-tested.
enum ProjectPageLogic {
    /// "31 decisions · 46 comments · last decision 12 min ago"; no last part before the first decision.
    static func statsLine(decisions: Int, comments: Int, lastDecisionAt: Date?, now: Date) -> String {
        var parts = [
            decisions == 1 ? "1 decision" : "\(decisions) decisions",
            comments == 1 ? "1 comment" : "\(comments) comments",
        ]
        if let lastDecisionAt { parts.append("last decision \(ago(lastDecisionAt, now: now))") }
        return parts.joined(separator: " · ")
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h ago" }
        let days = hours / 24
        if days < 7 { return days == 1 ? "1 day ago" : "\(days) days ago" }
        return dayMonth(date)
    }

    /// The date column: "Today 11:02", "Yesterday", then "12 Sep".
    static func dateLabel(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            let f = DateFormatter()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.dateFormat = "HH:mm"
            return "Today \(f.string(from: date))"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return dayMonth(date, calendar: calendar)
    }

    private static func dayMonth(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f.string(from: date)
    }

    /// "3 options · prototype": the option count and the artifact kind, each only when there is one.
    static func tag(optionCount: Int, artifactKind: String?) -> String {
        var parts: [String] = []
        if optionCount > 0 { parts.append(optionCount == 1 ? "1 option" : "\(optionCount) options") }
        if let artifactKind, let kind = ArtifactKind(rawValue: artifactKind) {
            parts.append(kind.indicatorLabel.lowercased())
        }
        return parts.joined(separator: " · ")
    }

    /// `9 comments · "knock-waggle-xza23H is not a name"`.
    static func evidenceLine(count: Int, quote: String?) -> String {
        let n = count == 1 ? "1 comment" : "\(count) comments"
        guard let quote, !quote.isEmpty else { return n }
        return "\(n) · \"\(quote)\""
    }

    static func themesLabel(comments: Int) -> String { "YOUR THEMES · FROM \(comments) COMMENTS" }

    static let themesHint = "On = sent to agents in this project before they build."
    static let themesEmpty = "No themes yet. Agents propose them from your comments."
    static let repoSwitchLabel = "Also write to docs/decisions/"
    static let pageSize = 50
}
