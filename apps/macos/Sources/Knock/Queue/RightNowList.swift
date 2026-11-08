import Foundation

/// What Home's cards (`HomeCards.swift`) borrow from the session and the ask: the summary line and
/// the answer line. Pure, so they are unit-tested without a window.
enum RightNowList {
    /// HAIL-178: a session with no title, goal or project (a Claude app chat that connected from "/")
    /// shows "Claude app · no decisions yet", or just its client name once it has asks, never a blank.
    static func summary(_ session: SessionInfo, hasAsks: Bool = true) -> String {
        let text = SessionContextDisplay.summary(session)
        guard text.isEmpty else { return text }
        return hasAsks ? session.runtimeLabel : "\(session.runtimeLabel) · no decisions yet"
    }

    /// The option title you picked, else the first line of your reply; nil when you did not answer.
    static func answerText(_ ask: Case) -> String? {
        guard ask.latestReplyAt != nil else { return nil }
        if !ask.latestReplyChoices.isEmpty { return ask.repliedChoiceTitles.joined(separator: ", ") }
        if let choice = ask.latestReplyChoice, !choice.isEmpty {
            return ask.repliedOptions.first { $0.id == choice }?.displayTitle ?? choice
        }
        return SessionContextBlock.firstLine(ask.latestReplyMessage)
    }
}
