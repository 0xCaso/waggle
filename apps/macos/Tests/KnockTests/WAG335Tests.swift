import Foundation
import Testing
@testable import Knock

/// WAG-335: one artifact word, honest key hints, and consistent round copy.
@MainActor
struct WAG335Tests {
    private func detail(_ name: String) throws -> CaseDetail {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/wag-282/\(name).json")
        return try JSONDecoder().decode(CaseDetail.self, from: Data(contentsOf: url))
    }

    // MARK: - T5: one label and menu word

    @Test func oneWordPerArtifactKindOnEveryScreen() {
        let words: [(ArtifactKind, String)] = [
            (.htmlBundle, "Prototype"), (.markdown, "Write-up"), (.screenshots, "Screenshots"),
            (.screenshot, "Screenshot"), (.diagram, "Diagram"),
        ]
        for (kind, word) in words {
            #expect(kind.indicatorLabel == word, "\(kind)")
            #expect(ArtifactTabs.defaultTitle(kind) == word, "\(kind)")
        }
        #expect(ArtifactVersionLabel.chrome(title: ArtifactTabs.defaultTitle(.markdown), revision: 1) == "Write-up · v1")
    }

    @Test func boxCaptionIsTheTabTitleWithNoLiveSuffix() {
        let tab = ArtifactTab(id: "kind:html_bundle", title: "Prototype", revision: 1, kind: .htmlBundle, hasName: false)
        #expect(LiveArtifactBoxView.caption(tab) == "Prototype")
    }

    @Test func keyHintsShowOnlyWhereTheKeysWork() {
        #expect(CanvasToolHint.content(for: .interact).title == "Interact · I")
        #expect(CanvasToolHint.content(for: .comment).title == "Comment · C")
        #expect(CanvasToolHint.content(for: .interact, showsKey: false).title == "Interact")
        #expect(CanvasToolHint.content(for: .comment, showsKey: false).title == "Comment")
    }

    // MARK: - T8: round copy

    @Test func wasLineNeedsNoStopAfterAQuestionMark() {
        let heading = RoundHeading.make(
            seq: 1, question: "Which layout now?", message: nil, originalTitle: "Which layout for the inbox?", answer: "Cards")
        #expect(heading?.was == "Was: Which layout for the inbox? · You answered: Cards")
        #expect(heading?.was.contains("?.") == false)
        #expect(heading?.earlier == RoundFoldEntry(question: "Which layout for the inbox?", answer: "Cards"))
    }

    @Test func noAnswerKeepsTheWasLineAndNoFold() {
        let heading = RoundHeading.make(
            seq: 1, question: "Which layout now?", message: nil, originalTitle: "Which layout for the inbox?", answer: nil)
        #expect(heading?.was == "Was: Which layout for the inbox?")
        #expect(heading?.earlier == nil)
    }

    @Test func roundToolbarSaysArrivedNotAnsweredWhileTheRoundWaits() {
        let arrived = Date(timeIntervalSince1970: 1_758_960_000)
        let now = arrived.addingTimeInterval(3 * 60)
        let label = CaseTimes.roundMetaLabel(
            round: 2, arrivedAt: arrived, answeredAt: arrived.addingTimeInterval(-60), isWaiting: true, now: now)
        #expect(label == "Round 2 · arrived \(KnockDateFormat.dateTime(from: arrived, now: now)) · waiting 3m")
        #expect(!label.contains("answered") && !label.contains("took"))
    }

    @Test func answeredRoundToolbarShowsTheNewAnswer() {
        let arrived = Date(timeIntervalSince1970: 1_758_960_000)
        let answered = arrived.addingTimeInterval(120)
        let label = CaseTimes.roundMetaLabel(round: 2, arrivedAt: arrived, answeredAt: answered, isWaiting: false, now: answered)
        #expect(label.hasSuffix("· answered \(KnockDateFormat.dateTime(from: answered, now: answered))"))
        // An answer from before the round is round 1's: it does not show.
        let old = CaseTimes.roundMetaLabel(
            round: 2, arrivedAt: arrived, answeredAt: arrived.addingTimeInterval(-5), isWaiting: false, now: answered)
        #expect(!old.contains("answered"))
    }

    @Test func updateRoundCaseUsesTheRoundToolbarAndHidesTheOldWhy() throws {
        let c = try detail("question-options").case
        #expect(c.roundNumber == 2)
        #expect(c.currentWhy == nil)
        let label = c.headerMetaLabel(now: Date())
        #expect(label.hasPrefix("Round 2 · arrived "))
        #expect(!label.contains("took"))
    }

    @Test func firstRoundKeepsItsToolbarAndWhy() throws {
        let c = try detail("message-only").case
        #expect(c.roundNumber == 1)
        #expect(c.currentWhy == c.why)
        #expect(c.headerMetaLabel(now: Date()).hasPrefix("Arrived "))
    }

    @Test func planFoldEntriesCarryTheAnswersOfEarlierRounds() throws {
        let d = try detail("plan-rounds")
        #expect(d.case.roundNumber == d.case.plan?.rounds)
        let earlier = PlanText.earlierAnswered(d.planRounds ?? [])
        let entries = PlanText.foldEntries(earlier)
        #expect(entries.count == earlier.count)
        #expect(entries.allSatisfy { !$0.question.isEmpty && !$0.answer.isEmpty })
    }
}
