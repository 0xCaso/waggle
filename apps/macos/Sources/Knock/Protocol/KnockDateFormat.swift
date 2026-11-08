import Foundation
import os

/// Parses docs/protocol-mvp.md's timestamp strings. The daemon always emits
/// `new Date().toISOString()` (with milliseconds); some hand-written test
/// fixtures omit them, so both are accepted.
enum KnockDateFormat {
    /// Parsed results by timestamp string. The same few thousand strings are parsed on every
    /// refresh and body evaluation, so the second look is a dictionary hit. A lock, not an
    /// actor: this runs from MainActor views and background enrichment alike.
    private static let cache = OSAllocatedUnfairLock<[String: Date]>(initialState: [:])
    private static let cacheLimit = 20_000

    // ISO8601DateFormatter is documented thread-safe, but Foundation does not mark it Sendable.
    // These two are built once and only ever read from. Building one per call cost 200-320 us.
    nonisolated(unsafe) private static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let withoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from string: String) -> Date? {
        if let hit = cache.withLock({ $0[string] }) { return hit }
        guard let date = parse(string) else { return nil }
        cache.withLock { cached in
            if cached.count >= cacheLimit { cached.removeAll(keepingCapacity: true) }
            cached[string] = date
        }
        return date
    }

    /// The uncached parse, kept separate so a test can time it.
    static func parse(_ string: String) -> Date? {
        withFractionalSeconds.date(from: string) ?? withoutFractionalSeconds.date(from: string)
    }

    /// A capture's "10:41" style clock time (docs/design/mvp-values.md §M5
    /// Capture chip). A fresh formatter per call for the same Sendable
    /// reason as `date(from:)`.
    static func shortTime(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// "27 Sep 21:28": the date and the clock time, for every moment the
    /// opened ask names (arrived, answered, changed, delivered). A time
    /// alone reads as today even when it was yesterday (operator,
    /// 2026-09-28). The year shows only when it is not the current one
    /// ("27 Sep 2025 21:28").
    static func dateTime(from date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "d MMM" : "d MMM y")
        return "\(formatter.string(from: date)) \(shortTime(from: date))"
    }

    /// The wire format for a timestamp this app produces itself
    /// (`Capture.taken_at`): `new Date().toISOString()`-equivalent, with
    /// fractional seconds, matching what the daemon emits.
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// A thread message's relative time label (docs/design/mvp-values.md §M9
    /// `vMRdd`, "just now"): under a minute reads as "just now", under an
    /// hour as "Nm ago", otherwise a plain clock time - the same falloff
    /// `IdleTime` uses for the queue row's idle label, in "ago" phrasing
    /// since this describes a past event, not an ongoing wait.
    static func relativeShort(from date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        return shortTime(from: date)
    }
}

extension Case {
    var createdAtDate: Date? { KnockDateFormat.date(from: createdAt) }
    var updatedAtDate: Date? { KnockDateFormat.date(from: updatedAt) }
    /// When the agent closed the case with a done update (HAIL-152).
    var doneAtDate: Date? { doneAt.flatMap(KnockDateFormat.date(from:)) }
    var sessionEndedAtDate: Date? { sessionEndedAt.flatMap(KnockDateFormat.date(from:)) }
    var lastCheckAtDate: Date? { lastCheckAt.flatMap(KnockDateFormat.date(from:)) }
    var latestReplyAtDate: Date? { latestReplyAt.flatMap(KnockDateFormat.date(from:)) }
    var latestReplyDeliveredAtDate: Date? { latestReplyDeliveredAt.flatMap(KnockDateFormat.date(from:)) }
}

extension Message {
    var createdAtDate: Date? { KnockDateFormat.date(from: createdAt) }
}
