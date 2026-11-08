import SwiftUI

/// What the app knows about the nudges it sent for one case's reply (HAIL-76).
/// Not persisted: the daemon keeps the real window and answers `rate_limited` itself.
struct NudgeRecord: Equatable, Sendable {
    /// Nudges the daemon accepted for this reply.
    var count = 0
    /// When the last accepted nudge was sent.
    var lastAt: Date?
    /// A `session.nudge` call is in flight.
    var sending = false
    /// Why the last attempt did not send. Nil after a nudge that sent.
    var failure: NudgeFailureReason?

    /// The record after a `session.nudge` answer.
    func applying(_ result: NudgeResult, at date: Date) -> NudgeRecord {
        var next = self
        next.sending = false
        if result.sent {
            next.count += 1
            next.lastAt = date
            next.failure = nil
        } else if result.reason == .rateLimited {
            // The daemon or the shim nudged this case in the last minute (the app
            // lost its record, for example after a restart). That is a nudge, not
            // an error: show "Nudged" and keep the window.
            next.count = max(next.count, 1)
            next.lastAt = next.lastAt ?? date
            next.failure = nil
        } else {
            next.failure = result.reason ?? .postFailed
        }
        return next
    }
}

/// The nudge (HAIL-76, docs/protocol-mvp.md "Reply not picked up"): one click
/// posts a line into the agent's session so it calls `knock_check` (HAIL-129:
/// always on for a session that can be nudged). The daemon allows one nudge per
/// case per minute.
enum Nudge {
    /// How long a sent nudge gets before the app calls the session still asleep.
    /// The same as the daemon's one-per-case window.
    static let wakeTimeout: TimeInterval = 60

    enum Phase: Equatable {
        /// No nudge control: the session cannot be nudged, a nudge failed (the
        /// fallback takes over), or the fallback is not showing yet.
        case off
        /// Show "Nudge".
        case ready
        /// "Nudged · 12s" while the nudge has its minute.
        case sent
        /// A nudge went out and 60 s passed. "Nudge again".
        case stillAsleep

        /// A nudge control or status is in play (not `off`).
        var isActive: Bool { self != .off }
    }

    static func phase(mode: PickupFallback.Mode, canNudge: Bool, record: NudgeRecord?, now: Date) -> Phase {
        guard canNudge, mode == .live else { return .off }
        // Any failure hands over to "Copy prompt" (the session cannot be nudged,
        // it ended, or the post failed).
        if record?.failure != nil { return .off }
        guard let record, record.count > 0 || record.sending else { return .ready }
        if record.sending { return .sent }
        if let last = record.lastAt, now.timeIntervalSince(last) < wakeTimeout { return .sent }
        return .stillAsleep
    }

    /// "Nudged · 12s": the time since the last accepted nudge. Under a minute in
    /// seconds, then minutes and seconds.
    static func nudgedLabel(since: Date?, now: Date) -> String {
        guard let since else { return "Nudging…" }
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        return seconds < 60 ? "Nudged · \(seconds)s" : "Nudged · \(seconds / 60)m \(seconds % 60)s"
    }

    /// Whether the reply was delivered after the app nudged for it.
    static func wokeUp(item: Case, record: NudgeRecord?) -> Bool {
        (record?.count ?? 0) > 0 && item.latestReplyState == .delivered
    }

    // MARK: Copy. Plain and friendly, no em-dashes.

    static let readyHelp = "It may have finished its turn. A nudge asks it to check Waggle for your reply."
    static let sentHelp = "If it is in the middle of a long step, it sees the nudge when that step ends."
    static let asleepHelp =
        "It has not woken up. It may be waiting on a prompt in its terminal, or it does not accept messages from other sessions."
    static let deliveredLine = "Delivered · it woke up and has your answer"
    static let wokeReadPrefix = "woke up after the nudge"

    static func nudgeLabel(runtime: String) -> String { "Nudge \(runtime)" }
    static let nudgeAgainLabel = "Nudge again"
    static let moreLabel = "More"

    /// One line under a failed attempt. Nil when there is nothing to say.
    static func failureLine(_ reason: NudgeFailureReason?) -> String? {
        switch reason {
        case .postFailed: "Waggle could not post the nudge. Copy the prompt instead."
        case .notSupported: "This session can't be nudged from Waggle. Copy the prompt instead."
        case .sessionClosed: "The session ended. Start it again and paste the prompt."
        case .alreadyPickedUp, .rateLimited, nil: nil
        }
    }
}

/// What the views need to show the nudge: which sessions can be nudged, the
/// app's records, and the action. Set once at the window's root.
struct NudgeContext: Sendable {
    var canNudgeByTaskId: [String: Bool] = [:]
    var records: [String: NudgeRecord] = [:]
    var send: @MainActor @Sendable (String) -> Void = { _ in }
    /// The "Copy prompt" click, reported as usage (HAIL-83).
    var copiedPrompt: @MainActor @Sendable () -> Void = {}

    func phase(for item: Case, mode: PickupFallback.Mode, now: Date) -> Nudge.Phase {
        Nudge.phase(
            mode: mode, canNudge: canNudgeByTaskId[item.taskId] ?? false,
            record: records[item.id], now: now)
    }
}

private struct NudgeContextKey: EnvironmentKey {
    static let defaultValue = NudgeContext()
}

extension EnvironmentValues {
    var nudge: NudgeContext {
        get { self[NudgeContextKey.self] }
        set { self[NudgeContextKey.self] = newValue }
    }
}
