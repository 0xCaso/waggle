import Testing
import Foundation
@testable import Knock

struct IdleTimeTests {
    @Test func formatsMinutesUnderAnHour() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(IdleTime.label(since: start, now: start.addingTimeInterval(60 * 18)) == "idle 18m")
    }

    @Test func flooredRatherThanRounded() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(IdleTime.label(since: start, now: start.addingTimeInterval(60 * 6 + 59)) == "idle 6m")
    }

    @Test func zeroAtTheMoment() {
        let now = Date()
        #expect(IdleTime.label(since: now, now: now) == "idle 0m")
    }

    @Test func neverGoesNegativeForAFutureDate() {
        let now = Date()
        #expect(IdleTime.label(since: now.addingTimeInterval(60), now: now) == "idle 0m")
    }

    @Test func formatsHoursAndMinutesAtAnHourOrMore() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(IdleTime.label(since: start, now: start.addingTimeInterval(60 * 65)) == "idle 1h 5m")
    }
}
