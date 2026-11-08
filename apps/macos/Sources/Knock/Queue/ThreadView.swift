import SwiftUI

/// Which asks show their whole thread, remembered for the session (HAIL-68).
/// One store for the pane and the review window, so both agree. `KNOCK_THREAD_EXPANDED=1`
/// starts every thread open (the evidence harness cannot click "Show all").
@MainActor
final class ThreadExpansionStore: ObservableObject {
    static let shared = ThreadExpansionStore()

    @Published private var expandedIds: Set<String> = []
    private let expandsAll: Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        expandsAll = environment["KNOCK_THREAD_EXPANDED"] == "1"
    }

    func isExpanded(_ caseId: String) -> Bool { expandsAll || expandedIds.contains(caseId) }

    func toggle(_ caseId: String) {
        if expandedIds.contains(caseId) { expandedIds.remove(caseId) } else { expandedIds.insert(caseId) }
    }
}

/// The last line of the thread: whose turn it is now.
struct ThreadTurn: Equatable {
    let status: AgentStatus
    /// Replaces the status's own label ("Your turn: approve v2 or ask for changes").
    let label: String
    /// Where the waiting timer starts.
    let since: Date?
}
