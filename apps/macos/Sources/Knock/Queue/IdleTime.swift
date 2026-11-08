import Foundation

/// Formats how long a case has been waiting (docs/design/mvp-values.md §2.3,
/// "idle 18m"). A pure function of two dates so it is unit-testable without
/// a running clock; `QueueListView` re-renders it once a minute by feeding
/// it a refreshed `now`.
enum IdleTime {
    static func label(since date: Date, now: Date) -> String {
        let totalMinutes = max(0, Int(now.timeIntervalSince(date) / 60))
        guard totalMinutes >= 60 else { return "idle \(totalMinutes)m" }
        return "idle \(totalMinutes / 60)h \(totalMinutes % 60)m"
    }
}
