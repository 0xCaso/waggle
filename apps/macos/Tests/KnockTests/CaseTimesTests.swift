import Foundation
import Testing
@testable import Knock

struct CaseTimesTests {
    // MARK: - compactDuration

    @Test func compactDurationReadsSecondsUnderAMinute() {
        #expect(CaseTimes.compactDuration(45) == "45s")
    }

    @Test func compactDurationReadsMinutesUnderAnHour() {
        #expect(CaseTimes.compactDuration(16 * 60) == "16m")
    }

    @Test func compactDurationReadsHoursAndMinutesUnderADay() {
        #expect(CaseTimes.compactDuration(2 * 3600 + 5 * 60) == "2h 5m")
    }

    @Test func compactDurationReadsWholeDaysAtOrOverADay() {
        #expect(CaseTimes.compactDuration(3 * 86400) == "3d")
    }

    @Test func compactDurationClampsANegativeIntervalToZero() {
        #expect(CaseTimes.compactDuration(-5) == "0s")
    }

    // MARK: - arrivalRowLabel

    // MARK: - arrivalTooltip

    @Test func arrivalTooltipIncludesBothDateAndTime() {
        let date = Date(timeIntervalSince1970: 1_758_960_000)
        let tooltip = CaseTimes.arrivalTooltip(for: date)
        // Full medium-date/short-time formatting is locale-dependent; assert
        // it is not just the bare clock time the row label alone would show.
        #expect(tooltip != KnockDateFormat.shortTime(from: date))
        #expect(!tooltip.isEmpty)
    }

    // MARK: - Case.tookLabel

    // MARK: - headerMetaLabel (opened-ask header meta, HAIL-34 21:38)

    @Test func headerMetaLabelReadsArrivedAndWaitingBeforeAnyReply() {
        let createdAt = Date(timeIntervalSince1970: 1_758_960_000)
        let now = createdAt.addingTimeInterval(12 * 60)
        let label = CaseTimes.headerMetaLabel(createdAt: createdAt, firstReplySubmittedAt: nil, now: now)
        #expect(label == "Arrived \(KnockDateFormat.dateTime(from: createdAt, now: now)) · waiting 12m")
    }

    @Test func headerMetaLabelReadsArrivedAnsweredAndTookOnceAReplyExists() {
        let createdAt = Date(timeIntervalSince1970: 1_758_960_000)
        let answeredAt = createdAt.addingTimeInterval(16 * 60)
        let now = answeredAt.addingTimeInterval(3600)
        let label = CaseTimes.headerMetaLabel(createdAt: createdAt, firstReplySubmittedAt: answeredAt, now: now)
        #expect(label == "Arrived \(KnockDateFormat.dateTime(from: createdAt, now: now)) · answered \(KnockDateFormat.dateTime(from: answeredAt, now: now)) · took 16m")
    }

    @Test func caseHeaderMetaLabelReadsItsOwnDates() {
        let item = Case.fixture(
            createdAt: "2026-09-27T21:14:00.000Z",
            firstReplySubmittedAt: "2026-09-27T21:30:00.000Z"
        )
        #expect(item.headerMetaLabel(now: Date()).contains("· took 16m"))
    }

    @Test func headerMetaLabelAppendsChangedWhenGiven() {
        let createdAt = Date(timeIntervalSince1970: 1_758_960_000)
        let answeredAt = createdAt.addingTimeInterval(16 * 60)
        let changedAt = answeredAt.addingTimeInterval(3 * 60)
        let label = CaseTimes.headerMetaLabel(
            createdAt: createdAt, firstReplySubmittedAt: answeredAt, changedAt: changedAt, now: changedAt
        )
        #expect(label == "Arrived \(KnockDateFormat.dateTime(from: createdAt, now: changedAt)) · answered \(KnockDateFormat.dateTime(from: answeredAt, now: changedAt)) · took 16m · changed \(KnockDateFormat.dateTime(from: changedAt, now: changedAt))")
    }

    // MARK: - CaseDetail.headerMetaLabel / latestReplyChangedAtDate (HAIL-34 21:38)

    @Test func latestReplyChangedAtDateIsNilForAReplyNeverChanged() {
        let detail = CaseDetail.fixture(
            latestReplyId: "reply_1",
            replies: [Reply.fixture(id: "reply_1", createdAt: "2026-09-27T21:30:00.000Z", replacedAt: nil)]
        )
        #expect(detail.latestReplyChangedAtDate == nil)
    }

    @Test func latestReplyChangedAtDateReadsTheCurrentRoundsReplacedAt() {
        let detail = CaseDetail.fixture(
            latestReplyId: "reply_1",
            replies: [Reply.fixture(id: "reply_1", createdAt: "2026-09-27T21:30:00.000Z", replacedAt: "2026-09-27T21:33:00.000Z")]
        )
        #expect(detail.latestReplyChangedAtDate == KnockDateFormat.date(from: "2026-09-27T21:33:00.000Z"))
    }

    @Test func caseDetailHeaderMetaLabelAppendsChangedFromItsOwnReply() {
        let detail = CaseDetail.fixture(
            createdAt: "2026-09-27T21:14:00.000Z",
            firstReplySubmittedAt: "2026-09-27T21:30:00.000Z",
            latestReplyId: "reply_1",
            replies: [Reply.fixture(id: "reply_1", createdAt: "2026-09-27T21:30:00.000Z", replacedAt: "2026-09-27T21:33:00.000Z")]
        )
        let now = Date()
        #expect(detail.headerMetaLabel(now: now).hasSuffix("· changed \(KnockDateFormat.dateTime(from: KnockDateFormat.date(from: "2026-09-27T21:33:00.000Z")!, now: now))"))
    }
}

private extension Case {
    static func fixture(
        createdAt: String = "2026-09-27T21:14:00.000Z", firstReplySubmittedAt: String?,
        latestReplyId: String? = nil
    ) -> Case {
        Case(
            id: "c_1", taskId: "t_1", kind: .question, title: "Title", need: "Need", why: "Why",
            recommendation: "a", recommendationWhy: "Why not", options: [], status: .waitingOnAgent,
            hasArtifact: false, latestReplyId: latestReplyId, firstReplySubmittedAt: firstReplySubmittedAt,
            createdAt: createdAt, updatedAt: createdAt
        )
    }
}

private extension CaseDetail {
    static func fixture(
        createdAt: String = "2026-09-27T21:14:00.000Z", firstReplySubmittedAt: String? = nil,
        latestReplyId: String?, replies: [Reply]
    ) -> CaseDetail {
        CaseDetail(
            case: .fixture(createdAt: createdAt, firstReplySubmittedAt: firstReplySubmittedAt, latestReplyId: latestReplyId),
            task: KnockTask(id: "t_1", name: "Task", project: "proj"),
            messages: [], revisions: [], comments: [], replies: replies
        )
    }
}

private extension Reply {
    static func fixture(id: String, createdAt: String, replacedAt: String?) -> Reply {
        Reply(
            id: id, caseId: "c_1", idempotencyKey: "k_\(id)", comments: [], captures: [],
            state: .queued, createdAt: createdAt, replacedAt: replacedAt
        )
    }
}

struct KnockDateTimeTests {
    // MARK: - dateTime (operator, 2026-09-28: "date time, not just time")

    @Test func dateTimeShowsTheDayAndTheTime() {
        let date = Date(timeIntervalSince1970: 1_758_960_000)
        let label = KnockDateFormat.dateTime(from: date, now: date.addingTimeInterval(86_400))
        #expect(label.hasSuffix(KnockDateFormat.shortTime(from: date)))
        #expect(label != KnockDateFormat.shortTime(from: date))
        #expect(!label.contains(String(Calendar.current.component(.year, from: date))))
    }

    @Test func dateTimeAddsTheYearOnlyForAnotherYear() {
        let date = Date(timeIntervalSince1970: 1_758_960_000)
        let nextYear = Calendar.current.date(byAdding: .year, value: 1, to: date)!
        #expect(KnockDateFormat.dateTime(from: date, now: nextYear).contains(String(Calendar.current.component(.year, from: date))))
    }

    // MARK: - agoLabel (row times, 29 Sep)

    @Test func agoLabelBuckets() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(CaseTimes.agoLabel(since: now.addingTimeInterval(-20), now: now) == "just now")
        #expect(CaseTimes.agoLabel(since: now.addingTimeInterval(-5 * 60), now: now) == "5m ago")
        #expect(CaseTimes.agoLabel(since: now.addingTimeInterval(-(2 * 3600 + 40 * 60)), now: now) == "2h ago")
        #expect(CaseTimes.agoLabel(since: now.addingTimeInterval(-3 * 86400), now: now) == "3d ago")
        #expect(CaseTimes.agoLabel(since: now.addingTimeInterval(60), now: now) == "just now")
    }

    @Test func agoLabelShowsADatePastAWeek() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let label = CaseTimes.agoLabel(since: now.addingTimeInterval(-10 * 86400), now: now)
        #expect(!label.hasSuffix("ago"))
        #expect(!label.isEmpty)
    }
}
