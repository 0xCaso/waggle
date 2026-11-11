import Foundation
import Testing
@testable import Knock

/// The pure rules of the first-run batch: which pane shows, which Getting started lines are done, whether the
/// card and the sample row show, and what the caught-up chips say.
@Suite("FirstRunRules")
struct FirstRunRulesTests {
    @Test func theSampleOpenAlwaysWinsThePane() {
        #expect(FirstRunRules.pane(sampleOpen: true, hasAnswered: false) == .sample)
        #expect(FirstRunRules.pane(sampleOpen: true, hasAnswered: true) == .sample)
    }

    @Test func theExplainerShowsOnlyBeforeTheFirstAnswerAndOnlyWithoutTheSample() {
        #expect(FirstRunRules.pane(sampleOpen: false, hasAnswered: false) == .explainer)
        #expect(FirstRunRules.pane(sampleOpen: false, hasAnswered: true) == .caughtUp)
    }

    @Test func anyAnswerCountsAsTheFirstAnswer() {
        #expect(!FirstRunRules.hasAnswered(decided: false, sampleAnswered: false, waitingCount: 0, answeredCount: 0))
        #expect(FirstRunRules.hasAnswered(decided: true, sampleAnswered: false, waitingCount: 0, answeredCount: 0))
        #expect(FirstRunRules.hasAnswered(decided: false, sampleAnswered: true, waitingCount: 0, answeredCount: 0))
        #expect(FirstRunRules.hasAnswered(decided: false, sampleAnswered: false, waitingCount: 1, answeredCount: 0))
        #expect(FirstRunRules.hasAnswered(decided: false, sampleAnswered: false, waitingCount: 0, answeredCount: 2))
    }

    @Test func theThreeLinesTickWhenTheirStepIsDone() {
        let none = FirstRunRules.lines(connected: false, connectedAgent: nil, sampleAnswered: false, ownRequest: false)
        #expect(none.map(\.title) == ["Connect an agent", "Answer the sample request", "Ask from your own session"])
        #expect(none.map(\.isDone) == [false, false, false])
        #expect(none[2].hint == "Tell your agent: ask me in Waggle.")
        let some = FirstRunRules.lines(connected: true, connectedAgent: "Codex", sampleAnswered: true, ownRequest: false)
        #expect(some.map(\.isDone) == [true, true, false])
        #expect(some[0].hint == "Codex is connected.")
    }

    @Test func theCardHidesWhenAllThreeAreDone() {
        let open = FirstRunRules.lines(connected: true, connectedAgent: nil, sampleAnswered: true, ownRequest: false)
        let done = FirstRunRules.lines(connected: true, connectedAgent: nil, sampleAnswered: true, ownRequest: true)
        #expect(FirstRunRules.showsCard(lines: open, hidden: false, forced: false))
        #expect(!FirstRunRules.showsCard(lines: done, hidden: false, forced: false))
        #expect(!FirstRunRules.showsCard(lines: open, hidden: true, forced: false))
        #expect(FirstRunRules.showsCard(lines: done, hidden: true, forced: true))
    }

    @Test func theSampleRowShowsOnlyOnAFirstOpen() {
        #expect(FirstRunRules.showsSampleRow(inboxEmpty: true, hasAnswered: false, sampleAnswered: false, sampleDismissed: false))
        #expect(!FirstRunRules.showsSampleRow(inboxEmpty: false, hasAnswered: false, sampleAnswered: false, sampleDismissed: false))
        #expect(!FirstRunRules.showsSampleRow(inboxEmpty: true, hasAnswered: true, sampleAnswered: false, sampleDismissed: false))
        #expect(!FirstRunRules.showsSampleRow(inboxEmpty: true, hasAnswered: false, sampleAnswered: true, sampleDismissed: false))
        #expect(!FirstRunRules.showsSampleRow(inboxEmpty: true, hasAnswered: false, sampleAnswered: false, sampleDismissed: true))
    }

    @Test func eachChipHidesAtZero() {
        #expect(FirstRunRules.chips(answeredToday: 0, agentsRunning: 0).isEmpty)
        let both = FirstRunRules.chips(answeredToday: 3, agentsRunning: 2)
        #expect(both == [CaughtUpChip(tone: .green, text: "3 answered today"), CaughtUpChip(tone: .blue, text: "2 agents working")])
        #expect(FirstRunRules.chips(answeredToday: 0, agentsRunning: 2).map(\.tone) == [.blue])
        #expect(FirstRunRules.chips(answeredToday: 1, agentsRunning: 0).map(\.tone) == [.green])
    }

    @Test func theCaughtUpCopyIsExactAndHasNoEmDash() {
        #expect(FirstRunRules.caughtUpTitle == "All caught up")
        #expect(FirstRunRules.caughtUpSubtitle == "Nothing needs you right now.")
        #expect(FirstRunRules.caughtUpQuietLine == "New requests land here. To start one, tell your agent: ask me in Waggle.")
        #expect(FirstRunRules.sampleMeta == "Sample · from Waggle · try answering it")
        #expect(FirstRunRules.sampleToolbarLine == "Sample request · nothing is sent to an agent")
        let all = [FirstRunRules.caughtUpTitle, FirstRunRules.caughtUpSubtitle, FirstRunRules.caughtUpQuietLine, FirstRunRules.sampleMeta, FirstRunRules.sampleToolbarLine]
        for text in all { #expect(!text.contains("\u{2014}")) }
    }
}
