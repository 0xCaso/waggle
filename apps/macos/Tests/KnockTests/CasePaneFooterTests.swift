import Testing
@testable import Knock

/// `CasePaneDetailView.footerKind`: which footer the case pane shows, as a
/// pure function of state (docs/stories/HAIL-34.md fold, gap 1 - "the queued
/// state and Change answer apply to the pane AND the review workspace, for
/// every ask kind"). Before HAIL-34 a review-kind pane fell straight through
/// to `openReviewBar` regardless of lock state, so a queued review ask's
/// pane never showed "Sent · waiting for the agent to pick it up" or "Change
/// answer" at all. Before HAIL-41 an *editable, unanswered* review ask also
/// fell straight to `openReviewBar` - the pane never showed a composer for a
/// review ask at all, only "Open review" (operator report: "why i cannot
/// comment in here and just select one of the options?").
struct CasePaneFooterTests {
    private func kind(
        kind: Case.Kind, lockState: ReplyLockState, isEditingLockedAnswer: Bool = false,
        hasConfirmedOutcome: Bool = false
    ) -> CasePaneDetailView.FooterKind {
        CasePaneDetailView.footerKind(
            kind: kind, lockState: lockState, isEditingLockedAnswer: isEditingLockedAnswer,
            hasConfirmedOutcome: hasConfirmedOutcome
        )
    }

    /// HAIL-41: an unanswered review ask now composes in the pane exactly
    /// like a question ask, not just "Open review".
    @Test func bothKindsComposeWhileEditableAndUnanswered() {
        #expect(kind(kind: .question, lockState: .editable) == .composer)
        #expect(kind(kind: .review, lockState: .editable) == .composer)
    }

    /// HAIL-41: "Change answer" on a review ask now edits in the pane too,
    /// same as a question ask - it used to hand off to the review workspace
    /// instead. `CasePaneDetailView.reviewChangeAnswerBar` wires its "Change
    /// answer" button to `sendFlow.beginChangingAnswer()` (kind-agnostic
    /// already - `SendFlowControllerTests.
    /// beginChangingAnswerRestoresTheExistingReplysCommentsAndCaptures`
    /// covers it for a review-kind case), which sets `isEditingLockedAnswer`
    /// - this is the pure function that then routes that state to
    /// `.composer` for either kind.
    @Test func bothKindsComposeWhileEditingALockedAnswer() {
        #expect(kind(kind: .question, lockState: .queued, isEditingLockedAnswer: true) == .composer)
        #expect(kind(kind: .review, lockState: .queued, isEditingLockedAnswer: true) == .composer)
    }

    @Test func questionKindShowsTheChangeAnswerBarWhileQueuedAndNotYetConfirmed() {
        #expect(kind(kind: .question, lockState: .queued) == .changeAnswerBar)
    }

    @Test func questionKindShowsTheConfirmedOutcomeOnceDeliveredOrFailed() {
        #expect(kind(kind: .question, lockState: .delivered, hasConfirmedOutcome: true) == .confirmedOutcome)
        #expect(kind(kind: .question, lockState: .failed, hasConfirmedOutcome: true) == .confirmedOutcome)
    }

    @Test func reviewKindShowsTheSentLineAndChangeAnswerWhileQueuedAndNotYetEditing() {
        #expect(kind(kind: .review, lockState: .queued) == .reviewChangeAnswerBar)
    }

    /// Once delivered or failed there is nothing left to edit in the pane
    /// for a review ask - it still falls back to "Open review" (the full
    /// workspace's own locked recap), same as before HAIL-41.
    @Test func reviewKindFallsBackToOpenReviewBarOnceConfirmed() {
        #expect(kind(kind: .review, lockState: .delivered, hasConfirmedOutcome: true) == .openReviewBar)
        #expect(kind(kind: .review, lockState: .failed, hasConfirmedOutcome: true) == .openReviewBar)
    }

    /// Regression (0.1.3 screenshot, operator amendment 2026-09-28 11:07): a
    /// delivered case once showed the green Delivered banner at the top AND
    /// "Sent · waiting for the agent to pick it up" in the footer at the same
    /// time. Both `deliveryOutcome`'s banner and `footerKind`'s
    /// `hasConfirmedOutcome` read the same `AppModel.deliveryStatusByCaseId`
    /// entry, so once it names a case Delivered, neither `changeAnswerBar`
    /// nor `reviewChangeAnswerBar` - the only footers carrying that queued
    /// line - can be reached for it, for either ask kind.
    @Test func aConfirmedOutcomeNeverRendersTheQueuedSentWaitingLineForEitherKind() {
        for caseKind: Case.Kind in [.question, .review] {
            for lockState: ReplyLockState in [.delivered, .failed] {
                let result = kind(kind: caseKind, lockState: lockState, hasConfirmedOutcome: true)
                #expect(result != .changeAnswerBar && result != .reviewChangeAnswerBar,
                        "\(caseKind)/\(lockState) resolved to \(result), which still carries the queued line")
            }
        }
    }
}
