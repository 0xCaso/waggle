import Foundation

/// Compact duration and clock-time formatting for queue rows and the opened
/// ask's header meta (docs/stories/HAIL-34.md, operator decision 21:38
/// "clock" + follow-up "I still want to track how long they take to solve a
/// specific ask"). Pure functions of dates, unit-testable without a running
/// clock - `AppModel.now`, ticking once a minute, feeds `now` the same way
/// `IdleTime` used to.
enum CaseTimes {
    /// "45s" / "16m" / "2h 5m" / "3d" - the compact duration bucket both
    /// "took" (answered rows, the opened ask's header) and "waiting"
    /// (pending, the opened ask's header) use. A fresh formatter is never
    /// needed here - this is pure arithmetic, no `DateFormatter`.
    static func compactDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval))
        if totalSeconds < 60 { return "\(totalSeconds)s" }
        let totalMinutes = totalSeconds / 60
        if totalMinutes < 60 { return "\(totalMinutes)m" }
        let totalHours = totalMinutes / 60
        if totalHours < 24 {
            return "\(totalHours)h \(totalMinutes % 60)m"
        }
        return "\(totalHours / 24)d"
    }

    /// The pending queue row's arrival time (docs/stories/HAIL-34.md 21:38):
    /// "21:14" today, the weekday within 7 days ("Sat"), else "12 Sep" - full
    /// date and time belongs in a tooltip (`arrivalTooltip`), not this label.
    /// A fresh `Calendar`/`DateFormatter` per call, not a cached static one -
    /// the same Sendable reasoning `KnockDateFormat` documents (this runs
    /// from both MainActor view code and background enrichment tasks).
    static func arrivalRowLabel(for date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return KnockDateFormat.shortTime(from: date)
        }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day ?? 0
        if (1..<7).contains(days) {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("EEE")
            return formatter.string(from: date)
        }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter.string(from: date)
    }

    /// How long ago, for queue rows (operator, 29 Sep: "i don't want
    /// 'took Xs' ... i want to know how long ago that message arrived
    /// there, or how long ago it was solved"): "just now", "5m ago",
    /// "2h ago", "3d ago", then the date ("12 Sep") past a week. Hours
    /// drop the minutes: a row label, not a stopwatch.
    static func agoLabel(since date: Date, now: Date) -> String {
        let totalSeconds = max(0, Int(now.timeIntervalSince(date)))
        if totalSeconds < 60 { return "just now" }
        let totalMinutes = totalSeconds / 60
        if totalMinutes < 60 { return "\(totalMinutes)m ago" }
        let totalHours = totalMinutes / 60
        if totalHours < 24 { return "\(totalHours)h ago" }
        let days = totalHours / 24
        if days < 7 { return "\(days)d ago" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter.string(from: date)
    }

    /// The full date and time for `arrivalRowLabel`'s tooltip.
    static func arrivalTooltip(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// The opened ask's own header meta (docs/stories/HAIL-34.md 21:38):
    /// "Arrived 21:14 · answered 21:30 · took 16m" once a first reply
    /// exists, else "Arrived 21:14 · waiting 12m" - the pending half ticks
    /// every minute since it reads straight off `now`. Shared by the case
    /// pane's toolbar and the review workspace's titlebar so the two never
    /// phrase this differently.
    /// `changedAt` (docs/stories/HAIL-34.md 21:38: "A changed answer
    /// (reply.replace) keeps the FIRST submit time for 'took', and shows
    /// 'changed 21:33' after it") appends one more segment once the current
    /// round's reply has been edited - `firstReplySubmittedAt`/"took" itself
    /// never moves, since `reply.replace` never touches the reply's own
    /// `created_at`.
    static func headerMetaLabel(createdAt: Date, firstReplySubmittedAt: Date?, changedAt: Date? = nil, now: Date) -> String {
        let arrived = "Arrived \(KnockDateFormat.dateTime(from: createdAt, now: now))"
        guard let firstReplySubmittedAt else {
            return "\(arrived) · waiting \(compactDuration(now.timeIntervalSince(createdAt)))"
        }
        let took = compactDuration(firstReplySubmittedAt.timeIntervalSince(createdAt))
        var label = "\(arrived) · answered \(KnockDateFormat.dateTime(from: firstReplySubmittedAt, now: now)) · took \(took)"
        if let changedAt {
            label += " · changed \(KnockDateFormat.dateTime(from: changedAt, now: now))"
        }
        return label
    }
}

extension CaseTimes {
    /// The toolbar line of a later round (WAG-335): "Round 2 · arrived 11:58 · waiting 3m". The first
    /// round's answer and "took" belong to round 1, so they never show here. Once you answer the round,
    /// "answered" takes the place of "waiting".
    static func roundMetaLabel(round: Int, arrivedAt: Date, answeredAt: Date?, isWaiting: Bool, now: Date) -> String {
        var label = "Round \(round) · arrived \(KnockDateFormat.dateTime(from: arrivedAt, now: now))"
        if isWaiting {
            label += " · waiting \(compactDuration(now.timeIntervalSince(arrivedAt)))"
        } else if let answeredAt, answeredAt >= arrivedAt {
            label += " · answered \(KnockDateFormat.dateTime(from: answeredAt, now: now))"
        }
        return label
    }
}

extension Case {
    var firstReplySubmittedAtDate: Date? { firstReplySubmittedAt.flatMap(KnockDateFormat.date(from:)) }

    /// "took 16m": time to answer = the first reply's `submitted_at` (i.e.
    /// `firstReplySubmittedAt`, never moved by a later `reply.replace` or a
    /// later round's own reply) minus the case's own `createdAt`. `nil`
    /// until the case has a first reply.
    var tookLabel: String? {
        guard let submittedAt = firstReplySubmittedAtDate, let createdAt = createdAtDate else { return nil }
        return "took \(CaseTimes.compactDuration(submittedAt.timeIntervalSince(createdAt)))"
    }

    /// `CaseTimes.headerMetaLabel` fed from this case's own dates - the
    /// opened ask's header meta, pane and review workspace alike. Never
    /// shows "changed" on its own: that needs the current round's full
    /// `Reply` (`CaseDetail.headerMetaLabel`, below), which a bare `Case`
    /// does not carry.
    func headerMetaLabel(now: Date, changedAt: Date? = nil, roundArrivedAt: Date? = nil) -> String {
        // A later round (an update with options, or a plan round) is a new request for you: the toolbar
        // says when it arrived, not when round 1 was answered (WAG-335, audit F15).
        if roundNumber > 1, let arrived = roundArrivedAt ?? optionsUpdatedAt.flatMap(KnockDateFormat.date(from:)) {
            return CaseTimes.roundMetaLabel(
                round: roundNumber, arrivedAt: arrived, answeredAt: latestReplyAt.flatMap(KnockDateFormat.date(from:)),
                isWaiting: status == .needsYou, now: now)
        }
        return CaseTimes.headerMetaLabel(
            createdAt: createdAtDate ?? now, firstReplySubmittedAt: firstReplySubmittedAtDate, changedAt: changedAt, now: now
        )
    }
}

extension CaseDetail {
    /// The current round's reply, if `reply.replace` has changed it since it
    /// was first sent (docs/stories/HAIL-34.md 21:38) - `nil` for a reply
    /// never edited, or no reply at all.
    var latestReplyChangedAtDate: Date? {
        replies.first(where: { $0.id == `case`.latestReplyId })?.replacedAt.flatMap(KnockDateFormat.date(from:))
    }

    /// `CaseTimes.headerMetaLabel` with the "changed HH:MM" segment this
    /// detail's own reply history can supply - the case pane and the review
    /// workspace both have a full `CaseDetail`, so both use this rather than
    /// `Case.headerMetaLabel`.
    func headerMetaLabel(now: Date) -> String {
        `case`.headerMetaLabel(now: now, changedAt: latestReplyChangedAtDate, roundArrivedAt: roundArrivedAtDate)
    }

    /// When the newest plan round arrived; `nil` for any other ask (its option set carries the time).
    var roundArrivedAtDate: Date? {
        guard `case`.plan != nil else { return nil }
        return planRounds?.last.flatMap { KnockDateFormat.date(from: $0.createdAt) }
    }
}
