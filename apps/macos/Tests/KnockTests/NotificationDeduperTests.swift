import Testing
import Foundation
@testable import Knock

/// Exercises `NotificationDeduper` against the contract: "No notification
/// for revisions of a case already notified within the last 60 s."
struct NotificationDeduperTests {
    @Test func firstNotificationForACaseAlwaysGoesThrough() {
        let deduper = NotificationDeduper()
        #expect(deduper.shouldNotify(caseId: "c_1", now: Date()) == true)
    }

    @Test func suppressesARepeatWithinTheSixtySecondWindow() {
        let deduper = NotificationDeduper()
        let first = Date(timeIntervalSince1970: 1_000)

        #expect(deduper.shouldNotify(caseId: "c_1", now: first) == true)
        #expect(deduper.shouldNotify(caseId: "c_1", now: first.addingTimeInterval(1)) == false)
        #expect(deduper.shouldNotify(caseId: "c_1", now: first.addingTimeInterval(59)) == false)
    }

    @Test func allowsAnotherNotificationOnceTheWindowHasPassed() {
        let deduper = NotificationDeduper()
        let first = Date(timeIntervalSince1970: 1_000)

        #expect(deduper.shouldNotify(caseId: "c_1", now: first) == true)
        #expect(deduper.shouldNotify(caseId: "c_1", now: first.addingTimeInterval(60)) == true)
    }

    @Test func tracksEachCaseIndependently() {
        let deduper = NotificationDeduper()
        let now = Date(timeIntervalSince1970: 1_000)

        #expect(deduper.shouldNotify(caseId: "c_1", now: now) == true)
        #expect(deduper.shouldNotify(caseId: "c_2", now: now) == true)
        #expect(deduper.shouldNotify(caseId: "c_1", now: now.addingTimeInterval(1)) == false)
        #expect(deduper.shouldNotify(caseId: "c_2", now: now.addingTimeInterval(1)) == false)
    }
}
