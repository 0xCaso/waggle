import Foundation

/// The "Remind me if an ask waits" scheduling/cancel rule (Contract: "one
/// more notification after 15 minutes if the ask is still waiting for you,
/// only once per ask; cancelled when answered or dismissed"), as a pure
/// function of the current `needs_you` case set and the caller's own prior
/// state - no `Task`/`Timer` inside, so the story's required test ("reminder
/// scheduling/cancel logic as pure functions") needs no clock mocking, and
/// `AppModel` can drive it from any tick (an event's `refreshCases()`, or the
/// existing once-a-minute clock) without double-firing.
enum AskReminderScheduler {
    static let delay: TimeInterval = 15 * 60

    struct Outcome: Equatable {
        /// Cases still waiting on their 15-minute mark.
        var pending: [String: Date]
        /// Cases whose reminder should fire right now.
        var due: [String]
        /// Cases already reminded once - excluded from `pending` until they
        /// leave `needsYouCaseIds` (a later, fresh ask can remind again).
        var reminded: Set<String>
    }

    /// - Parameters:
    ///   - needsYouCaseIds: every case currently in `needs_you`.
    ///   - pending: this case's own prior `pending` (fire-at date per case
    ///     id), from the last call.
    ///   - reminded: this case's own prior `reminded`, from the last call.
    ///   - enabled: the Settings toggle's current value, read by the caller.
    ///   - now: the instant to schedule from / compare against.
    static func reconcile(
        needsYouCaseIds: Set<String>,
        pending: [String: Date],
        reminded: Set<String>,
        enabled: Bool,
        now: Date
    ) -> Outcome {
        // Cancel: a case no longer needs_you (answered or dismissed) drops
        // its pending entry and its reminded mark, so it starts clean if a
        // later ask on the same case reaches needs_you again.
        var pending = pending.filter { needsYouCaseIds.contains($0.key) }
        var reminded = reminded.intersection(needsYouCaseIds)

        guard enabled else {
            return Outcome(pending: [:], due: [], reminded: reminded)
        }

        // Schedule: a needs_you case with neither a pending entry nor a past
        // reminder gets one 15 minutes out.
        for caseId in needsYouCaseIds where pending[caseId] == nil && !reminded.contains(caseId) {
            pending[caseId] = now.addingTimeInterval(delay)
        }

        // Fire: a pending entry whose mark has passed - "only once per ask",
        // so it moves straight to `reminded` and leaves `pending`.
        let due = pending.filter { $0.value <= now }.keys.sorted()
        for caseId in due {
            pending.removeValue(forKey: caseId)
            reminded.insert(caseId)
        }

        return Outcome(pending: pending, due: due, reminded: reminded)
    }
}
