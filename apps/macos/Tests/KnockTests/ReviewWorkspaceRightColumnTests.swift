import Testing
@testable import Knock

/// `ReviewWorkspaceView.rightColumnKind`: which right column the review
/// workspace shows, as a pure function of state (docs/stories/HAIL-34.md
/// operator report 21:37 - "the review workspace ignores the delivery
/// state ... Open review still opens a live composer with 'Accept
/// recommendation' and an empty reply field"). For each of Queued/Delivered/
/// Failed the workspace must show the case pane's answered view, hiding the composer and
/// the Accept button, unless "Change answer" has put it back into edit mode.
struct ReviewWorkspaceRightColumnTests {
    private func kind(
        lockState: ReplyLockState, isEditingLockedAnswer: Bool = false,
        isReviewingBeforeSend: Bool = false, tab: ReviewColumnTab = .question
    ) -> ReviewWorkspaceView.RightColumnKind {
        ReviewWorkspaceView.rightColumnKind(
            lockState: lockState, isEditingLockedAnswer: isEditingLockedAnswer,
            isReviewingBeforeSend: isReviewingBeforeSend, tab: tab
        )
    }

    @Test func editableFallsThroughToTheNormalQuestionOrCommentsSwitch() {
        #expect(kind(lockState: .editable, tab: .question) == .interact)
        #expect(kind(lockState: .editable, tab: .comments) == .comments)
    }

    @Test func queuedDeliveredAndFailedAllShowTheAskWithStatusRegardlessOfTab() {
        #expect(kind(lockState: .queued, tab: .comments) == .askWithStatus)
        #expect(kind(lockState: .delivered, tab: .comments) == .askWithStatus)
        #expect(kind(lockState: .failed, tab: .comments) == .askWithStatus)
        #expect(kind(lockState: .delivered, tab: .question) == .askWithStatus)
    }

    @Test func changeAnswerReturnsToTheNormalComposerEvenWhileLocked() {
        #expect(kind(lockState: .queued, isEditingLockedAnswer: true, tab: .question) == .interact)
        #expect(kind(lockState: .delivered, isEditingLockedAnswer: true, tab: .comments) == .comments)
    }

    @Test func reviewingBeforeSendAlwaysWinsEvenWhileEditingALockedAnswer() {
        #expect(kind(lockState: .queued, isEditingLockedAnswer: true, isReviewingBeforeSend: true) == .reviewBeforeSend)
        #expect(kind(lockState: .editable, isReviewingBeforeSend: true) == .reviewBeforeSend)
    }

    /// `ReviewWorkspaceView.isAnswerLocked` (docs/stories/HAIL-34.md fold:
    /// "Hide the Comment option ... once the answer is locked") - the switch
    /// hides for queued (not yet changed) and delivered, and comes back the
    /// moment "Change answer" starts editing again.
    @Test func artifactViewerHidesCommentWhileQueuedOrDeliveredAndUnlessEditing() {
        #expect(ReviewWorkspaceView.isAnswerLocked(lockState: .editable, isEditingLockedAnswer: false) == false)
        #expect(ReviewWorkspaceView.isAnswerLocked(lockState: .queued, isEditingLockedAnswer: false))
        #expect(ReviewWorkspaceView.isAnswerLocked(lockState: .delivered, isEditingLockedAnswer: false))
        #expect(ReviewWorkspaceView.isAnswerLocked(lockState: .failed, isEditingLockedAnswer: false))
        #expect(ReviewWorkspaceView.isAnswerLocked(lockState: .queued, isEditingLockedAnswer: true) == false)
        #expect(ReviewWorkspaceView.isAnswerLocked(lockState: .delivered, isEditingLockedAnswer: true) == false)
    }
}
