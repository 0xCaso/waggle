import Foundation

/// What the main window shows first (the first-run batch). Every rule here is a pure function: the views
/// only draw what these return, and tests call them with plain values.
enum MainPane: Equatable {
    /// The three-step explainer. Only before the first answer, and never while the sample is open.
    case explainer
    /// The sample request, open on the real request page.
    case sample
    /// "All caught up": the inbox is empty and the person has answered at least once.
    case caughtUp
}

/// One line of the three-line Getting started card.
enum FirstRunLine: CaseIterable, Equatable {
    case connect, sample, ownSession

    var title: String {
        switch self {
        case .connect: "Connect an agent"
        case .sample: "Answer the sample request"
        case .ownSession: "Ask from your own session"
        }
    }
}

struct FirstRunLineItem: Equatable, Identifiable {
    let line: FirstRunLine
    let isDone: Bool
    let hint: String
    var id: FirstRunLine { line }
    var title: String { line.title }
}

/// The two chips of the caught-up pane.
struct CaughtUpChip: Equatable {
    enum Tone: Equatable { case green, blue }
    let tone: Tone
    let text: String
}

enum FirstRunRules {
    static let sampleTitle = "Pricing card: compact or detailed?"
    static let sampleMeta = "Sample · from Waggle · try answering it"
    static let sampleToolbarLine = "Sample request · nothing is sent to an agent"
    static let caughtUpTitle = "All caught up"
    static let caughtUpSubtitle = "Nothing needs you right now."
    static let caughtUpQuietLine = "New requests land here. To start one, tell your agent: ask me in Waggle."
    /// The pane with no request open while the list still holds some (a paused Waggle, or nothing picked yet).
    static let noSelectionLine = "Pick a request from the list to open it."

    /// Which pane the empty main window shows. The sample comes first. Otherwise the first answer decides
    /// between the explainer (not answered yet) and the caught-up pane.
    static func pane(sampleOpen: Bool, hasAnswered: Bool) -> MainPane {
        if sampleOpen { return .sample }
        return hasAnswered ? .caughtUp : .explainer
    }

    /// The person has answered at least once: a real answer (the model saw one), the sample, or an answer
    /// the list already holds.
    static func hasAnswered(decided: Bool, sampleAnswered: Bool, waitingCount: Int, answeredCount: Int) -> Bool {
        decided || sampleAnswered || waitingCount > 0 || answeredCount > 0
    }

    /// The three lines, each done when its step is done.
    static func lines(connected: Bool, connectedAgent: String?, sampleAnswered: Bool, ownRequest: Bool) -> [FirstRunLineItem] {
        [
            FirstRunLineItem(
                line: .connect, isDone: connected,
                hint: connected ? "\(connectedAgent ?? "Your agent") is connected." : "Connect Claude Code, Codex or the Claude app."),
            FirstRunLineItem(
                line: .sample, isDone: sampleAnswered,
                hint: sampleAnswered ? "You answered the sample." : "Pick an option and press Decide."),
            FirstRunLineItem(
                line: .ownSession, isDone: ownRequest,
                hint: ownRequest ? "Your agent asked you in Waggle." : "Tell your agent: ask me in Waggle."),
        ]
    }

    /// The card hides when all three lines are done, or after Hide. The Help menu forces it back.
    static func showsCard(lines: [FirstRunLineItem], hidden: Bool, forced: Bool) -> Bool {
        forced || (!hidden && !lines.allSatisfy(\.isDone))
    }

    /// The one sample row in the list column: only for a first open (no request, nothing answered), and never
    /// again after the sample is answered or dismissed.
    static func showsSampleRow(inboxEmpty: Bool, hasAnswered: Bool, sampleAnswered: Bool, sampleDismissed: Bool) -> Bool {
        inboxEmpty && !hasAnswered && !sampleAnswered && !sampleDismissed
    }

    /// Green "N answered today" and blue "N agents working". Each hides at zero.
    static func chips(answeredToday: Int, agentsRunning: Int) -> [CaughtUpChip] {
        var chips: [CaughtUpChip] = []
        if answeredToday > 0 { chips.append(CaughtUpChip(tone: .green, text: "\(answeredToday) answered today")) }
        if agentsRunning > 0 {
            chips.append(CaughtUpChip(tone: .blue, text: agentsRunning == 1 ? "1 agent working" : "\(agentsRunning) agents working"))
        }
        return chips
    }
}
