import Foundation

/// Which answered asks are still really waiting on the agent, and which have
/// moved on to the collapsed "Answered" group (HAIL-64). A view grouping only:
/// nothing here changes a case in the daemon. All functions are pure, so the
/// rule, the 10 minute boundary and the day sections are unit-testable
/// without a view or a clock.
enum AnswerGrouping {
    /// How long a delivered reply stays in "Waiting on agent" after pickup.
    static let pickupWindow: TimeInterval = 10 * 60

    /// True for a case that was replaced or dismissed (HAIL-130): it never belongs in
    /// "Waiting on agent", whatever status the app last saw for it.
    static func isClosed(_ item: Case) -> Bool {
        item.withdrawnAt != nil || item.dismissedAt != nil || item.status == .resolved
    }

    /// True when a case the app has as `waiting_on_agent` still belongs in
    /// "Waiting on agent". Checked in this order:
    /// 1. The reply is not picked up (queued, failed, or not known): it stays,
    ///    so Retry and "Waiting for pickup" stay visible - unless the agent
    ///    has clearly moved on: its session is not live and the reply is 10
    ///    minutes old, or a newer ask from the same task follows it (operator,
    ///    29 Sep: day-old replies from closed sessions sat in "Waiting on agent").
    /// 2. The session is closed, ended or disconnected: it moves.
    /// 3. A newer ask from the same task follows it: it moves.
    /// 4. A delivered "ask for more detail" with a live session: it stays
    ///    (the agent is writing).
    /// 5. Picked up less than 10 minutes ago: it stays. At 10 minutes it moves.
    static func staysWaiting(_ item: Case, isFollowedUp: Bool, now: Date) -> Bool {
        // A done case stays in view until the human taps Got it (HAIL-152), whatever follows it.
        if item.isDone { return true }
        guard item.latestReplyState == .delivered else {
            if isFollowedUp { return false }
            if let session = item.sessionState, session != .live,
               let sentAt = item.latestReplyAtDate ?? item.updatedAtDate,
               now.timeIntervalSince(sentAt) >= pickupWindow {
                return false
            }
            return true
        }
        if let session = item.sessionState, session != .live { return false }
        if isFollowedUp { return false }
        if item.isTalkingItOver { return true }
        guard let pickedUpAt = item.latestReplyDeliveredAtDate ?? item.latestReplyAtDate ?? item.updatedAtDate else {
            return true
        }
        return now.timeIntervalSince(pickedUpAt) < pickupWindow
    }

    /// Ids of asks that a newer ask from the same task follows: an ask that
    /// names it in `follows` or `replaces`, or simply any newer case on that
    /// task. `allCases` is every open case the app knows (both queue groups).
    static func followedUpIds(in allCases: [Case]) -> Set<String> {
        var newestByTask: [String: Date] = [:]
        var ids: Set<String> = []
        for item in allCases {
            if let created = item.createdAtDate, created > (newestByTask[item.taskId] ?? .distantPast) {
                newestByTask[item.taskId] = created
            }
            if let followsId = item.followsCaseId { ids.insert(followsId) }
            if let replacesId = item.replacesCaseId { ids.insert(replacesId) }
        }
        for item in allCases {
            if let created = item.createdAtDate, let newest = newestByTask[item.taskId], created < newest {
                ids.insert(item.id)
            }
        }
        return ids
    }

    /// What an answered ask shows instead of a live status (HAIL-104): when it was
    /// picked up, and the ask that followed it.
    struct Settled: Equatable {
        struct FollowUp: Equatable {
            let id: String
            let title: String
        }
        let pickedUpAt: Date?
        let followUp: FollowUp?
    }

    /// Non-nil when `item` waits on the agent but `staysWaiting` says it is answered. The same
    /// rule as the queue grouping, so the card, the strip and the list agree.
    static func settled(_ item: Case, allCases: [Case], deliveredAt: Date? = nil, now: Date) -> Settled? {
        guard item.status == .waitingOnAgent else { return nil }
        let followed = followedUpIds(in: allCases)
        guard !staysWaiting(item, isFollowedUp: followed.contains(item.id), now: now) else { return nil }
        return Settled(pickedUpAt: deliveredAt ?? item.latestReplyDeliveredAtDate, followUp: followUp(of: item, in: allCases))
    }

    /// The ask that follows `item`: one that names it in `follows` or `replaces`, else the
    /// next newer ask on the same task.
    static func followUp(of item: Case, in allCases: [Case]) -> Settled.FollowUp? {
        let others = allCases.filter { $0.id != item.id }
        let direct = others.filter { $0.followsCaseId == item.id || $0.replacesCaseId == item.id }
        var next = direct.min { ($0.createdAtDate ?? .distantFuture) < ($1.createdAtDate ?? .distantFuture) }
        if next == nil, let created = item.createdAtDate {
            next = others.filter { $0.taskId == item.taskId && ($0.createdAtDate ?? .distantPast) > created }
                .min { ($0.createdAtDate ?? .distantFuture) < ($1.createdAtDate ?? .distantFuture) }
        }
        return next.map { Settled.FollowUp(id: $0.id, title: $0.title) }
    }

    /// Splits the `waiting_on_agent` cases into the ones still waiting and the
    /// answered ones. Each side keeps the input order (newest created first).
    static func split(
        waiting: [Case], allCases: [Case], now: Date
    ) -> (waiting: [Case], answered: [Case]) {
        let followed = followedUpIds(in: allCases)
        var stillWaiting: [Case] = []
        var answered: [Case] = []
        for item in waiting where !isClosed(item) {
            if staysWaiting(item, isFollowedUp: followed.contains(item.id), now: now) {
                stillWaiting.append(item)
            } else {
                answered.append(item)
            }
        }
        answered.sort { lhs, rhs in
            let l = answeredAt(lhs) ?? .distantPast
            let r = answeredAt(rhs) ?? .distantPast
            if l != r { return l > r }
            return lhs.id < rhs.id
        }
        return (stillWaiting, answered)
    }

    /// When the human answered: the latest reply's time. It is the age the
    /// Answered rows show and the day they sit in.
    static func answeredAt(_ item: Case) -> Date? {
        item.latestReplyAtDate ?? item.firstReplySubmittedAtDate ?? item.createdAtDate
    }

    struct DaySection: Equatable {
        /// "TODAY", "YESTERDAY", or the date ("SEP 27", with the year when it
        /// is not this year).
        let title: String
        let cases: [Case]
        var header: String { "\(title) · \(cases.count)" }
    }

    /// Day sections, newest day first. `answered` must already be newest first.
    static func daySections(
        _ answered: [Case], now: Date, calendar: Calendar = .current, locale: Locale = .current
    ) -> [DaySection] {
        var sections: [DaySection] = []
        var currentDay: Date?
        var bucket: [Case] = []
        var bucketTitle = ""
        func flush() {
            if !bucket.isEmpty { sections.append(DaySection(title: bucketTitle, cases: bucket)) }
            bucket = []
        }
        for item in answered {
            let at = answeredAt(item) ?? now
            let day = calendar.startOfDay(for: at)
            if day != currentDay {
                flush()
                currentDay = day
                bucketTitle = dayTitle(for: day, now: now, calendar: calendar, locale: locale)
            }
            bucket.append(item)
        }
        flush()
        return sections
    }

    static func dayTitle(for day: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "TODAY" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "YESTERDAY"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMM d" : "MMM d yyyy")
        return formatter.string(from: day).uppercased(with: locale)
    }
}

/// Whether the Answered group is open, remembered across launches (HAIL-64).
/// Closed by default.
enum AnsweredGroupSettings {
    static let key = "queueAnsweredGroupOpen"

    static func isOpen(defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? false
    }

    static func setOpen(_ open: Bool, defaults: UserDefaults = .standard) {
        defaults.set(open, forKey: key)
    }
}
