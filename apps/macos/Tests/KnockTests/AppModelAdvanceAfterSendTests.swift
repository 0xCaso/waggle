import Foundation
import Testing
@testable import Knock

/// `AppModel.nextCaseId(afterAnswering:in:)` (Contract "Next ask"): the pure
/// next-case selection rule - below, else above, else none - and the
/// "Sent" toast's state, copy and timer (HAIL-79).
/// `@MainActor`: `nextCaseId` is a static member of the `@MainActor`-isolated
/// `AppModel`.
@MainActor
struct AppModelAdvanceAfterSendTests {
    private func makeCase(_ id: String) -> Case {
        Case(
            id: id, taskId: "t1", kind: .question, title: "Title \(id)",
            need: "N", why: "W", recommendation: "R", recommendationWhy: "RW",
            options: [], status: .needsYou, hasArtifact: false,
            createdAt: "2026-09-26T10:00:00Z", updatedAt: "2026-09-26T10:00:00Z"
        )
    }

    // MARK: - nextCaseId

    @Test func selectsTheCaseBelowWhenOneExists() {
        let cases = [makeCase("a"), makeCase("b"), makeCase("c")]
        #expect(AppModel.nextCaseId(afterAnswering: "a", in: cases) == "b")
    }

    @Test func fallsBackToTheCaseAboveWhenAnsweringTheLastRow() {
        let cases = [makeCase("a"), makeCase("b"), makeCase("c")]
        #expect(AppModel.nextCaseId(afterAnswering: "c", in: cases) == "b")
    }

    @Test func returnsNilWhenItWasTheOnlyCase() {
        let cases = [makeCase("a")]
        #expect(AppModel.nextCaseId(afterAnswering: "a", in: cases) == nil)
    }

    @Test func returnsNilWhenTheAnsweredCaseIsNotInTheList() {
        // The "Change answer" case (Contract): a case already answered and
        // moved to waiting_on_agent is not in `needsYouCases` at all.
        let cases = [makeCase("a"), makeCase("b")]
        #expect(AppModel.nextCaseId(afterAnswering: "z", in: cases) == nil)
    }

    // MARK: - Sent toast (HAIL-79)

    @Test func toastPhaseFollowsTheReplyState() {
        #expect(SentToast.phase(lockState: .queued, delivery: nil) == .queued)
        #expect(SentToast.phase(lockState: .editable, delivery: .sent) == .queued)
        #expect(SentToast.phase(lockState: .queued, delivery: .delivered(at: Date())) == .delivered)
        #expect(SentToast.phase(lockState: .delivered, delivery: nil) == .delivered)
        #expect(SentToast.phase(lockState: .queued, delivery: .failed(replyId: "r1")) == .failed)
        #expect(SentToast.phase(lockState: .failed, delivery: nil) == .failed)
    }

    @Test func toastCopyAndChangeAnswerByPhase() {
        let queued = SentToastContent(phase: .queued)
        #expect(queued.headline == "Sent · waiting for pickup")
        #expect(queued.showsChangeAnswer)
        let delivered = SentToastContent(phase: .delivered)
        #expect(delivered.headline == "Delivered · the agent has your answer")
        #expect(!delivered.showsChangeAnswer)
        let failed = SentToastContent(phase: .failed)
        #expect(failed.headline == "Not delivered · open the decision to retry")
        #expect(!failed.showsChangeAnswer)
        #expect(queued.youLine(answer: "Compact") == "You → Compact")
        #expect(queued.youLine(answer: "") == "")
    }

    @Test func clockFadesTwoAndAHalfSecondsAfterDelivery() {
        var clock = SentToastClock()
        for _ in 0..<40 { clock.advance(by: 0.1, isHovering: false, isDelivered: false) }
        #expect(!clock.shouldFade)
        for _ in 0..<24 { clock.advance(by: 0.1, isHovering: false, isDelivered: true) }
        #expect(!clock.shouldFade)
        clock.advance(by: 0.1, isHovering: false, isDelivered: true)
        #expect(clock.shouldFade)
    }

    @Test func clockNeverPassesTenSecondsWhileQueued() {
        var clock = SentToastClock()
        for _ in 0..<97 { clock.advance(by: 0.1, isHovering: false, isDelivered: false) }
        #expect(!clock.shouldFade)
        clock.advance(by: 0.1, isHovering: false, isDelivered: false)
        // Fade starts by 9.75 s and lasts 0.25 s: gone by about 10 s.
        #expect(clock.shouldFade)
    }

    @Test func hoverPausesTheClock() {
        var clock = SentToastClock()
        for _ in 0..<200 { clock.advance(by: 0.1, isHovering: true, isDelivered: true) }
        #expect(!clock.shouldFade)
        #expect(clock.elapsed == 0)
        clock.advance(by: 0.1, isHovering: false, isDelivered: false)
        #expect(clock.elapsed > 0)
    }
}
