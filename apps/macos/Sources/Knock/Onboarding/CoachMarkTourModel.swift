import Foundation

/// The tour of the first real ask (WAG-338): three marks, shown once, skippable at any point. It floats
/// over the ask in the main window, so `MainWindowView` holds a reference (shared through `KnockApp`).
///
/// 1. "What the agent brings": the artifact box.
/// 2. "Decide or keep talking": the options.
/// 3. "A new round": the round crumb and title, shown when the agent comes back after Keep talking.
///
/// Marks 1 and 2 run together from `start(caseId:)`. Mark 3 starts later, on its own, from
/// `startRound(caseId:)`. `GettingStartedModel` decides when each starts and remembers that it ran.
@MainActor
final class CoachMarkTourModel: ObservableObject {
    enum Mark: Int, CaseIterable, Equatable {
        case artifact = 1
        case options
        case round

        var counterLabel: String { "\(rawValue) of \(Mark.allCases.count)" }

        var title: String {
            switch self {
            case .artifact: "What the agent brings"
            case .options: "Decide or keep talking"
            case .round: "A new round"
            }
        }

        var body: String {
            switch self {
            case .artifact:
                "Each option comes with its own prototype or write-up. Click the tabs to compare them."
            case .options:
                "Pick an option and press Decide. Not sure? Lean ◐, rule out ×, or ask: the agent answers in a new round."
            case .round:
                "You kept talking, so the agent came back with a new round. Every round stays in your history."
            }
        }

        /// "Next" moves to the next mark; the last mark of a run says "Got it".
        var buttonLabel: String { self == .artifact ? "Next" : "Got it" }
    }

    enum EndReason: Equatable {
        case skipped
        /// The run ended after this mark: `.options` ends marks 1 and 2, `.round` ends mark 3.
        case completed(Mark)
    }

    /// The case id the tour is running over, so a stray action from another ask never moves it.
    @Published private(set) var activeCaseId: String?
    @Published private(set) var currentMark: Mark?

    /// Told once when a run ends, so the app can remember it.
    var onEnd: (EndReason) -> Void = { _ in }

    var isActive: Bool { activeCaseId != nil }

    /// Starts marks 1 and 2 on `caseId`. Restarts cleanly if a tour was already running.
    func start(caseId: String) {
        UsageReporter.current?.record(.tourStarted)
        activeCaseId = caseId
        currentMark = .artifact
    }

    /// Starts mark 3 on `caseId`: the agent came back with a new round.
    func startRound(caseId: String) {
        activeCaseId = caseId
        currentMark = .round
    }

    func isShowingRound(for caseId: String) -> Bool { activeCaseId == caseId && currentMark == .round }

    /// "Skip": ends the tour outright, from any mark.
    func skip() {
        guard isActive else { return }
        activeCaseId = nil
        currentMark = nil
        UsageReporter.current?.record(.tourSkipped)
        onEnd(.skipped)
    }

    /// "Next" or "Got it".
    func next() {
        guard let mark = currentMark else { return }
        switch mark {
        case .artifact:
            currentMark = .options
        case .options, .round:
            activeCaseId = nil
            currentMark = nil
            UsageReporter.current?.record(.tourFinished)
            onEnd(.completed(mark))
        }
    }

    /// Ends a tour without telling anyone: setup restarted from the menu.
    func reset() {
        activeCaseId = nil
        currentMark = nil
    }
}
