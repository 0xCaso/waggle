import Testing
import Foundation
@testable import Knock

struct KnockDateFormatTests {
    @Test func parsesTheDaemonsFractionalSecondsFormat() {
        #expect(KnockDateFormat.date(from: "2026-09-26T10:41:00.123Z") != nil)
    }

    @Test func parsesTestFixturesWithoutFractionalSeconds() {
        #expect(KnockDateFormat.date(from: "2026-09-26T10:41:00Z") != nil)
    }

    @Test func rejectsGarbage() {
        #expect(KnockDateFormat.date(from: "not a date") == nil)
    }

    @Test func caseExposesCreatedAndUpdatedAsDates() {
        let item = Case(
            id: "c_1", taskId: "t_1", kind: .question, title: "T",
            need: "N", why: "W", recommendation: "R", recommendationWhy: "RW",
            options: [], status: .needsYou, hasArtifact: false,
            createdAt: "2026-09-26T10:00:00.000Z", updatedAt: "2026-09-26T10:41:00.000Z"
        )
        #expect(item.createdAtDate != nil)
        #expect(item.updatedAtDate! > item.createdAtDate!)
    }

    /// docs/design/mvp-values.md §M9 `vMRdd`: the Thread message's relative
    /// timestamp, "just now" under a minute, "Nm ago" under an hour.
    @Test func relativeShortReadsJustNowUnderAMinute() {
        let now = Date()
        #expect(KnockDateFormat.relativeShort(from: now.addingTimeInterval(-5), now: now) == "just now")
    }

    @Test func relativeShortReadsMinutesAgoUnderAnHour() {
        let now = Date()
        #expect(KnockDateFormat.relativeShort(from: now.addingTimeInterval(-5 * 60), now: now) == "5m ago")
    }

    @Test func relativeShortFallsBackToAClockTimeAtAnHourOrMore() {
        let now = Date()
        let result = KnockDateFormat.relativeShort(from: now.addingTimeInterval(-3600), now: now)
        #expect(result != "just now")
        #expect(!result.hasSuffix("ago"))
    }
}
