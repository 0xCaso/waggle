import Foundation

/// The "All caught up" empty state's three stats (Contract "All caught up":
/// "answered today", "median time to decide today", "waiting on agents").
/// Pure functions of the client's own currently-known cases - there is no
/// persisted history beyond what the queue already holds (Non-goals: "stats
/// history beyond today"), so "answered today" only ever counts a case this
/// app instance still has in `waitingOnAgentCases` (see the Choices ledger).
enum CaughtUpStats {
    struct Values: Equatable {
        let answeredToday: Int
        /// `nil` when no case was answered today - there is no median of an
        /// empty set. The view shows "–" for this case (Contract: "Show a
        /// stat as "–" when there is no data").
        let medianTimeToDecideTodaySeconds: TimeInterval?
        /// Live agent sessions right now (the footer's count). Not the
        /// "Waiting on agent" group: answered asks stay there after delivery,
        /// so that count only ever grew (operator, 29 Sep: "waiting on 76 agents?").
        let agentsRunning: Int

        var answeredTodayLabel: String { "\(answeredToday)" }
        var medianTimeToDecideTodayLabel: String {
            medianTimeToDecideTodaySeconds.map { CaseTimes.compactDuration($0) } ?? "–"
        }
        var agentsRunningLabel: String { "\(agentsRunning)" }
    }

    /// `waitingOnAgentCases` (`firstReplySubmittedAtDate` falling on `now`'s
    /// calendar day) is the only source of "replies you sent today" the
    /// client has: a case answered and since dismissed, or answered in an
    /// earlier app session this one never fetched, is not counted.
    static func compute(waitingOnAgentCases: [Case], liveSessionCount: Int, now: Date) -> Values {
        let calendar = Calendar.current
        let decideDurationsToday: [TimeInterval] = waitingOnAgentCases.compactMap { item in
            guard let submittedAt = item.firstReplySubmittedAtDate,
                  calendar.isDate(submittedAt, inSameDayAs: now),
                  let createdAt = item.createdAtDate
            else { return nil }
            return submittedAt.timeIntervalSince(createdAt)
        }
        return Values(
            answeredToday: decideDurationsToday.count,
            medianTimeToDecideTodaySeconds: median(of: decideDurationsToday),
            agentsRunning: liveSessionCount
        )
    }

    /// The middle value of a sorted list, or the mean of the two middle
    /// values for an even count. `nil` for an empty list - undefined, not 0.
    static func median(of values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
