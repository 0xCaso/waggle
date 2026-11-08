import Testing
import Foundation
@testable import Knock

/// "N earlier asks" on the crumbs line and its popover (WAG-257, case c_e6dab43f).
struct EarlierAsksTests {
    private func makeCase(
        id: String, task: String = "t1", title: String = "Ask", created: String, options: [Option] = [],
        replyChoice: String? = nil, replyMessage: String? = nil, replyAt: String? = nil
    ) -> Case {
        Case(
            id: id, taskId: task, kind: .question, title: title, need: "N", why: "W", recommendation: "", recommendationWhy: "",
            options: options, status: .needsYou, hasArtifact: false,
            latestReplyAt: replyAt, latestReplyChoice: replyChoice, latestReplyMessage: replyMessage,
            createdAt: created, updatedAt: created)
    }

    private let now = ISO8601DateFormatter().date(from: "2026-10-07T12:00:00Z")!
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    @Test func hiddenWhenThereAreNoEarlierAsks() {
        let current = makeCase(id: "c3", created: "2026-10-07T11:00:00Z")
        let other = makeCase(id: "x", task: "t2", created: "2026-10-07T09:00:00Z")
        let model = EarlierAsksModel.make(item: current, cases: [other], now: now, calendar: utc)
        #expect(model.rows.isEmpty && model.linkLabel == nil)
    }

    @Test func oneRowPerEarlierAskOfTheSameSession() {
        let options = [Option(id: "a", label: "Flagged first", title: "Flagged first")]
        let first = makeCase(
            id: "c1", title: "Which inbox?", created: "2026-10-07T08:00:00Z", options: options,
            replyChoice: "a", replyAt: "2026-10-07T08:30:00Z")
        let second = makeCase(
            id: "c2", title: "Name it", created: "2026-10-07T09:00:00Z", replyMessage: "Call it Waggle", replyAt: "2026-10-07T09:10:00Z")
        let current = makeCase(id: "c3", created: "2026-10-07T11:00:00Z")
        let model = EarlierAsksModel.make(
            item: current, cases: [second, current, first], now: now, calendar: utc, timeZone: TimeZone(identifier: "UTC")!)
        #expect(model.rows.map(\.id) == ["c1", "c2"])
        #expect(model.rows[0].outcome == "You picked: Flagged first" && model.rows[0].time == "08:30")
        #expect(model.rows[1].outcome == "You: Call it Waggle" && model.rows[1].time == "09:10")
        #expect(model.linkLabel == "2 earlier requests")
        #expect(model.footer == "Thread: 3 steps today")
    }

    @Test func singularLabelsAndLongRepliesAreShort() {
        let long = makeCase(
            id: "c1", created: "2026-10-06T08:00:00Z", replyMessage: String(repeating: "word ", count: 40), replyAt: "2026-10-06T08:30:00Z")
        let current = makeCase(id: "c2", created: "2026-10-07T11:00:00Z")
        let model = EarlierAsksModel.make(item: current, cases: [long], now: now, calendar: utc)
        #expect(model.linkLabel == "1 earlier request")
        #expect(model.footer == "Thread: 1 step today")
        #expect(model.rows[0].outcome.count <= "You: ".count + EarlierAsksModel.shortReplyLimit + 1)
        #expect(model.rows[0].outcome.hasSuffix("…"))
    }

    @Test func anUnansweredAskSaysSo() {
        let open = makeCase(id: "c1", created: "2026-10-07T08:00:00Z")
        let current = makeCase(id: "c2", created: "2026-10-07T11:00:00Z")
        let model = EarlierAsksModel.make(item: current, cases: [open], now: now, calendar: utc)
        #expect(model.rows[0].outcome == "No answer yet" && !model.rows[0].isAnswered)
    }
}
