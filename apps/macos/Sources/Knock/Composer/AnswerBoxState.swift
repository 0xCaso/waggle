import Foundation

/// What the answer box shows once the agent has updated the ask (HAIL-108,
/// operator decision D). `Case.options` and `Case.recommendation` are always
/// the current option set; this says how the box frames them. An update without
/// options keeps the current set as it is (HAIL-125), so it is `.original`.
enum AnswerBoxState: Equatable, Sendable {
    /// No update with options is the news: the current options, nothing folded.
    case original
    /// The newest step is an update WITH options: a blue header, the update's
    /// options, and a "First options" link that reveals the first set.
    case updateWithOptions(updatedAt: Date?, firstAt: Date?)

    static func make(for item: Case) -> AnswerBoxState {
        // A plan round is a new round, not an update to an answered ask (HAIL-151).
        guard item.status == .needsYou, !item.options.isEmpty, item.plan == nil else { return .original }
        let optionsAt = item.optionsUpdatedAt.flatMap(KnockDateFormat.date(from:))
        let replyAt = item.latestReplyAtDate
        if let optionsAt, replyAt.map({ optionsAt > $0 }) ?? true {
            return .updateWithOptions(updatedAt: optionsAt, firstAt: KnockDateFormat.date(from: item.createdAt))
        }
        // An update WITHOUT options leaves the current set as it is (HAIL-125).
        return .original
    }

    static func header(at date: Date?, timeZone: TimeZone = .current) -> String {
        "↻ Options from the update" + suffix(date, timeZone)
    }

    static func firstOptionsDivider(at date: Date?, timeZone: TimeZone = .current) -> String {
        "FIRST OPTIONS" + suffix(date, timeZone)
    }

    static func firstOptionsLink(isOpen: Bool) -> String { isOpen ? "Hide first options" : "First options" }

    private static func suffix(_ date: Date?, _ timeZone: TimeZone) -> String {
        date.map { " · " + ThreadCopy.clock($0, timeZone: timeZone) } ?? ""
    }
}
