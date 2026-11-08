import Testing
import Foundation
@testable import Knock

// HAIL-113: the pane selects a Needs you ask on its own when it is empty.
struct AutoSelectTests {
    private func makeCase(_ id: String, status: CaseStatus = .needsYou) -> Case {
        Case(
            id: id, taskId: "t_1", kind: .question, title: "Title",
            need: "Need", why: "Why", recommendation: "a",
            recommendationWhy: "Because", options: [], status: status,
            hasArtifact: false, latestReplyId: nil, latestReplyState: nil, latestReplyAt: nil,
            sessionState: .live,
            createdAt: "2026-09-30T09:00:00.000Z", updatedAt: "2026-09-30T10:00:00.000Z"
        )
    }

    private func target(
        selected: String?, shows: Bool, known: [String], needsYou: [Case],
        arrival: Bool = false, unsent: Bool = false
    ) -> String? {
        AppModel.autoSelectTarget(
            selectedCaseId: selected, paneShowsCase: shows, knownCaseIds: known, needsYou: needsYou,
            hasNewArrival: arrival, holdsUnsentWork: unsent)
    }

    @Test func emptyPaneAndNewAskSelectsTheTopAsk() {
        let asks = [makeCase("b"), makeCase("a")]
        #expect(target(selected: nil, shows: false, known: ["b", "a"], needsYou: asks) == "b")
    }

    @Test func viewingACaseStaysOnIt() {
        let asks = [makeCase("b")]
        #expect(target(selected: "a", shows: true, known: ["a", "b"], needsYou: asks) == nil)
    }

    @Test func viewingAnAnsweredCaseStaysOnIt() {
        #expect(target(selected: "w", shows: true, known: ["w", "n"], needsYou: [makeCase("n")]) == nil)
    }

    @Test func aSelectionStillLoadingIsKept() {
        #expect(target(selected: "a", shows: false, known: ["a", "b"], needsYou: [makeCase("b")]) == nil)
    }

    @Test func onlyWaitingCasesStayEmpty() {
        #expect(target(selected: nil, shows: false, known: ["w1", "w2"], needsYou: []) == nil)
    }

    @Test func answeredLastAskWithAnotherNeedsYouSelectsIt() {
        // The answered case left Needs you and the pane fell back to empty.
        #expect(target(selected: nil, shows: false, known: ["a", "n"], needsYou: [makeCase("n")]) == "n")
    }

    @Test func aGoneSelectionWithEmptyPaneSelectsTheTopAsk() {
        #expect(target(selected: "gone", shows: false, known: ["n"], needsYou: [makeCase("n")]) == "n")
    }

    // HAIL-118

    @Test func viewingAnAnsweredCaseAndANewAskArrivesMovesToTheTopAsk() {
        #expect(target(selected: "w", shows: true, known: ["w", "n"], needsYou: [makeCase("n")], arrival: true) == "n")
    }

    @Test func viewingAnAnsweredCaseWithNothingNewStays() {
        #expect(target(selected: "w", shows: true, known: ["w", "n"], needsYou: [makeCase("n")]) == nil)
    }

    @Test func viewingANeedsYouCaseAndANewAskArrivesStays() {
        let asks = [makeCase("n"), makeCase("a")]
        #expect(target(selected: "a", shows: true, known: ["n", "a"], needsYou: asks, arrival: true) == nil)
    }

    @Test func unsentWorkKeepsTheSelectionWhenANewAskArrives() {
        #expect(target(selected: "w", shows: true, known: ["w", "n"], needsYou: [makeCase("n")],
                       arrival: true, unsent: true) == nil)
    }

    @Test func aClosedSelectionWithNoNeedsYouAskStays() {
        #expect(target(selected: "x", shows: true, known: ["x"], needsYou: [], arrival: true) == nil)
    }
}
