import Testing
import Foundation
@testable import Knock

struct CaseDisplayTests {
    private func makeCase(recommendation: String, options: [Option]) -> Case {
        Case(
            id: "c_1", taskId: "t_1", kind: .review, title: "Title",
            need: "Need", why: "Why", recommendation: recommendation,
            recommendationWhy: "Because", options: options, status: .needsYou,
            hasArtifact: false, createdAt: "2026-09-26T10:00:00.000Z",
            updatedAt: "2026-09-26T10:00:00.000Z"
        )
    }

    private func makeCase(taskName: String, project: String, runtime: Runtime) -> Case {
        Case(
            id: "c_1", taskId: "t_1", kind: .review, title: "Title",
            need: "Need", why: "Why", recommendation: "R",
            recommendationWhy: "Because", options: [], status: .needsYou,
            hasArtifact: false, runtime: runtime, taskName: taskName, project: project,
            createdAt: "2026-09-26T10:00:00.000Z", updatedAt: "2026-09-26T10:00:00.000Z"
        )
    }

    private func makeCase(status: CaseStatus, sessionState: SessionState?) -> Case {
        Case(
            id: "c_1", taskId: "t_1", kind: .question, title: "Title",
            need: "Need", why: "Why", recommendation: "R",
            recommendationWhy: "Because", options: [], status: status,
            hasArtifact: false, sessionState: sessionState,
            createdAt: "2026-09-26T10:00:00.000Z", updatedAt: "2026-09-26T10:00:00.000Z"
        )
    }

    private func makeAnsweredCase(
        status: CaseStatus = .waitingOnAgent,
        recommendation: String = "a",
        options: [Option] = [Option(id: "a", label: "Compact"), Option(id: "b", label: "Change something")],
        latestReplyId: String? = "reply_1",
        latestReplyState: ReplyStatus? = nil,
        latestReplyChoice: String? = nil,
        latestReplyMessage: String? = nil,
        latestReplyIntent: ReplyIntent? = nil,
        sessionState: SessionState? = nil
    ) -> Case {
        Case(
            id: "c_1", taskId: "t_1", kind: .question, title: "Title",
            need: "Need", why: "Why", recommendation: recommendation,
            recommendationWhy: "Because", options: options, status: status,
            hasArtifact: false, latestReplyId: latestReplyId, latestReplyState: latestReplyState,
            latestReplyChoice: latestReplyChoice, latestReplyMessage: latestReplyMessage,
            latestReplyIntent: latestReplyIntent, sessionState: sessionState,
            createdAt: "2026-09-26T10:00:00.000Z", updatedAt: "2026-09-26T10:00:00.000Z"
        )
    }

    // MARK: - Answer lock (HAIL-34)

    @Test func isAnswerLockedOnceAReplyExistsAndTheCaseLeftNeedsYou() {
        #expect(makeAnsweredCase(status: .waitingOnAgent, latestReplyId: "reply_1").isAnswerLocked)
        #expect(makeAnsweredCase(status: .resolved, latestReplyId: "reply_1").isAnswerLocked)
        #expect(!makeAnsweredCase(status: .needsYou, latestReplyId: "reply_1").isAnswerLocked)
        #expect(!makeAnsweredCase(status: .waitingOnAgent, latestReplyId: nil).isAnswerLocked)
    }

    // MARK: - replyLockState (HAIL-34)

    @Test func replyLockStateIsEditableBeforeAnyReplyOrOnceANewRoundStarts() {
        #expect(makeAnsweredCase(status: .waitingOnAgent, latestReplyId: nil).replyLockState == .editable)
        #expect(makeAnsweredCase(status: .needsYou, latestReplyId: "reply_1").replyLockState == .editable)
    }

    @Test func replyLockStateIsQueuedWhileTheReplyAwaitsPickup() {
        #expect(makeAnsweredCase(latestReplyState: .queued).replyLockState == .queued)
        #expect(makeAnsweredCase(latestReplyState: nil).replyLockState == .queued, "no latest_reply_state yet still reads as queued, not delivered")
    }

    @Test func replyLockStateIsDeliveredOnceTheAgentHasPickedItUp() {
        #expect(makeAnsweredCase(latestReplyState: .delivered).replyLockState == .delivered)
    }

    @Test func replyLockStateIsFailedOnceDeliveryFails() {
        #expect(makeAnsweredCase(latestReplyState: .failed).replyLockState == .failed)
    }

    // MARK: - "you → …" row line (HAIL-34)

    @Test func answeredSummaryLineSaysYouAskedForADetailRequest() {
        #expect(makeAnsweredCase(latestReplyMessage: "Explain the trade-offs", latestReplyIntent: .moreDetail).answeredSummaryLine
            == "you asked: Explain the trade-offs")
        #expect(makeAnsweredCase(latestReplyMessage: nil, latestReplyIntent: .moreDetail).answeredSummaryLine
            == "you asked: more detail")
    }

    @Test func answeredSummaryLineUsesTheOptionTitle() {
        let options = [Option(id: "a", label: "Compact: one screen, fewer fields", title: "Compact"), Option(id: "b", label: "Detailed: everything on one page")]
        #expect(makeAnsweredCase(recommendation: "a", options: options, latestReplyChoice: "a").answeredSummaryLine == "you → accepted: Compact")
        #expect(makeAnsweredCase(recommendation: "a", options: options, latestReplyChoice: "b").answeredSummaryLine == "you → Detailed")
    }

    @Test func recommendationDisplayUsesTheOptionTitle() {
        let item = makeCase(recommendation: "a", options: [Option(id: "a", label: "A · Compact: one screen", title: "Tight")])
        #expect(item.recommendationDisplay == "Tight")
    }

    @Test func answeredSummaryLineIsNilWithoutAReply() {
        #expect(makeAnsweredCase(latestReplyId: nil).answeredSummaryLine == nil)
    }

    @Test func answeredSummaryLineMarksAnAcceptedRecommendation() {
        let item = makeAnsweredCase(recommendation: "a", latestReplyChoice: "a")
        #expect(item.answeredSummaryLine == "you → accepted: Compact")
    }

    @Test func answeredSummaryLineNamesAChosenOptionThatDiffersFromTheRecommendation() {
        let item = makeAnsweredCase(recommendation: "a", latestReplyChoice: "b")
        #expect(item.answeredSummaryLine == "you → Change something")
    }

    @Test func answeredSummaryLineAppendsTheCommentAfterTheChoice() {
        let item = makeAnsweredCase(recommendation: "a", latestReplyChoice: "b", latestReplyMessage: "Why don't we make the button blue?")
        #expect(item.answeredSummaryLine == "you → Change something · Why don't we make the button blue?")
    }

    /// docs/stories/HAIL-36.md: "with no choice and a message, 'you →
    /// <message>'" - an options case whose reply carried no choice (the
    /// operator typed a note without ever picking an option) reads the
    /// message alone, never "accepted: <recommendation>".
    @Test func answeredSummaryLineForAnOptionsCaseWithNoChoiceReadsTheMessage() {
        let item = makeAnsweredCase(recommendation: "a", latestReplyChoice: nil, latestReplyMessage: "Let's hold off for now.")
        #expect(item.answeredSummaryLine == "you → Let's hold off for now.")
    }

    @Test func answeredSummaryLineForAFreeTextCaseReadsTheMessage() {
        let item = makeAnsweredCase(recommendation: "Ship as is", options: [], latestReplyMessage: "Let's hold off for now.")
        #expect(item.answeredSummaryLine == "you → Let's hold off for now.")
    }

    @Test func answeredSummaryLineForAFreeTextCaseMarksAnAcceptedRecommendation() {
        let item = makeAnsweredCase(recommendation: "Ship as is", options: [], latestReplyMessage: "Ship as is")
        #expect(item.answeredSummaryLine == "you → accepted: Ship as is")
    }

    @Test func resolvesAnOptionRecommendationToItsLabelAlone() {
        let item = makeCase(recommendation: "a", options: [Option(id: "a", label: "A · Compact"), Option(id: "b", label: "B · Detailed")])
        #expect(item.recommendationDisplay == "Compact")
    }

    @Test func doesNotPrependTheOptionIdWhenTheLabelHasNoLetterOfItsOwn() {
        let item = makeCase(recommendation: "a", options: [Option(id: "a", label: "70 / 25 / 5")])
        #expect(item.recommendationDisplay == "70 / 25 / 5")
    }

    @Test func leavesAFreeTextRecommendationAsIs() {
        let item = makeCase(recommendation: "70 / 25 / 5", options: [])
        #expect(item.recommendationDisplay == "70 / 25 / 5")
    }

    @Test func leavesARecommendationThatMatchesNoOptionAsIs() {
        let item = makeCase(recommendation: "ship as is", options: [Option(id: "a", label: "Compact")])
        #expect(item.recommendationDisplay == "ship as is")
    }

    @Test func artifactKindIndicatorLabels() {
        #expect(ArtifactKind.htmlBundle.indicatorLabel == "Prototype")
        #expect(ArtifactKind.screenshot.indicatorLabel == "Screenshot")
        #expect(ArtifactKind.markdown.indicatorLabel == "Write-up")
        #expect(ArtifactKind.screenshots.indicatorLabel == "Screenshots")
    }

    // MARK: - isWaitingOnMoreDetail (HAIL-33)

    @Test func isWaitingOnMoreDetailOnlyWhileQueuedWithAMoreDetailReply() {
        #expect(makeAnsweredCase(latestReplyState: .queued, latestReplyIntent: .moreDetail).isWaitingOnMoreDetail)
        #expect(!makeAnsweredCase(latestReplyState: .queued, latestReplyIntent: .decision).isWaitingOnMoreDetail)
        #expect(!makeAnsweredCase(latestReplyState: .delivered, latestReplyIntent: .moreDetail).isWaitingOnMoreDetail)
        #expect(!makeAnsweredCase(status: .needsYou, latestReplyId: nil, latestReplyIntent: .moreDetail).isWaitingOnMoreDetail)
    }

    // MARK: - followUpRecapLine (HAIL-33 amendment)

    @Test func followUpRecapLineIsNilWithoutAReply() {
        #expect(makeAnsweredCase(latestReplyId: nil).followUpRecapLine == nil)
    }

    @Test func followUpRecapLineNamesTheChosenOptionAndTheMessage() {
        let item = makeAnsweredCase(recommendation: "a", latestReplyChoice: "b", latestReplyMessage: "Why don't we make the button blue?")
        #expect(item.followUpRecapLine == "You chose: Change something. Why don't we make the button blue?")
    }

    @Test func followUpRecapLineNamesTheChosenOptionAlone() {
        let item = makeAnsweredCase(recommendation: "a", latestReplyChoice: "b")
        #expect(item.followUpRecapLine == "You chose: Change something")
    }

    @Test func followUpRecapLineForAFreeTextCaseReadsTheMessage() {
        let item = makeAnsweredCase(recommendation: "Ship as is", options: [], latestReplyMessage: "Let's hold off for now.")
        #expect(item.followUpRecapLine == "You chose: Let's hold off for now.")
    }

    @Test func collapsesTheSessionLabelWhenTheTaskNameDuplicatesTheProject() {
        let task = KnockTask(id: "t_1", name: "weekend-league", project: "weekend-league")
        #expect(task.sessionLabel(runtime: .claude) == "weekend-league · Claude Code")
    }

    @Test func keepsTheSessionLabelInThreePartsWhenTheTaskNameDiffersFromTheProject() {
        let task = KnockTask(id: "t_1", name: "Card pricing", project: "weekend-league")
        #expect(task.sessionLabel(runtime: .claude) == "weekend-league · Card pricing · Claude Code")
    }

    @Test func showsTheCodexDisplayNameForACodexSessionLabel() {
        let task = KnockTask(id: "t_1", name: "weekend-league", project: "weekend-league")
        #expect(task.sessionLabel(runtime: .codex) == "weekend-league · Codex")
    }

    @Test func runtimeDisplayNames() {
        #expect(Runtime.claude.displayName == "Claude Code")
        #expect(Runtime.codex.displayName == "Codex")
    }

    @Test func collapsesTheBreadcrumbWhenTheTaskNameDuplicatesTheProject() {
        let task = KnockTask(id: "t_1", name: "omea-web", project: "omea-web")
        #expect(task.breadcrumb(separator: "  /  ") == "omea-web")
        #expect(task.breadcrumb(separator: " · ") == "omea-web")
    }

    @Test func keepsTheBreadcrumbInTwoPartsWhenTheTaskNameDiffersFromTheProject() {
        let task = KnockTask(id: "t_1", name: "Checkout redesign", project: "omea-web")
        #expect(task.breadcrumb(separator: "  /  ") == "omea-web  /  Checkout redesign")
        #expect(task.breadcrumb(separator: " · ") == "omea-web · Checkout redesign")
    }

    /// HAIL-28 AC: the queue row's meta line reads `Case`'s own denormalized
    /// `taskName`/`project`/`runtime` - no `cases.get` enrichment needed to
    /// fill it in, so it can never sit blank waiting for one.
    @Test func caseSessionLabelKeepsThreePartsWhenTheTaskNameDiffersFromTheProject() {
        let item = makeCase(taskName: "Card pricing", project: "weekend-league", runtime: .claude)
        #expect(item.sessionLabel == "weekend-league · Card pricing · Claude Code")
    }

    @Test func caseSessionLabelCollapsesWhenTheTaskNameDuplicatesTheProject() {
        let item = makeCase(taskName: "weekend-league", project: "weekend-league", runtime: .codex)
        #expect(item.sessionLabel == "weekend-league · Codex")
    }

    // MARK: - Dismiss confirmation gate (HAIL-32)

    @Test func needsDismissConfirmationOnlyForANeedsYouCaseWithALiveSession() {
        #expect(makeCase(status: .needsYou, sessionState: .live).needsDismissConfirmation)
        #expect(!makeCase(status: .needsYou, sessionState: .disconnected).needsDismissConfirmation)
        #expect(!makeCase(status: .needsYou, sessionState: .ended).needsDismissConfirmation)
        #expect(!makeCase(status: .needsYou, sessionState: nil).needsDismissConfirmation)
        #expect(!makeCase(status: .waitingOnAgent, sessionState: .live).needsDismissConfirmation)
        #expect(!makeCase(status: .resolved, sessionState: .live).needsDismissConfirmation)
    }

    // MARK: - Row "Waiting for pickup" (HAIL-32 state 2)

    @Test func waitingForPickupShowsOnlyForAWaitingOnAgentCaseWithNoConfirmedOutcome() {
        let waiting = makeCase(status: .waitingOnAgent, sessionState: .live)
        #expect(waiting.showsWaitingForPickup(deliveryStatus: nil))
        #expect(waiting.showsWaitingForPickup(deliveryStatus: .sent))
        #expect(waiting.showsWaitingForPickup(deliveryStatus: .sending))
        #expect(!waiting.showsWaitingForPickup(deliveryStatus: .delivered(at: Date())))
        #expect(!waiting.showsWaitingForPickup(deliveryStatus: .failed(replyId: "r_1")))

        let needsYou = makeCase(status: .needsYou, sessionState: .live)
        #expect(!needsYou.showsWaitingForPickup(deliveryStatus: nil))
    }

    // MARK: - Stale queued reply safety net (HAIL-44)

    @Test func isStaleQueuedReplyOnlyForAWaitingOnAgentCaseWithAQueuedReplyAndAnEndedSession() {
        let stale = makeAnsweredCase(status: .waitingOnAgent, latestReplyState: .queued, sessionState: .ended)
        #expect(stale.isStaleQueuedReply)

        #expect(!makeAnsweredCase(status: .waitingOnAgent, latestReplyState: .queued, sessionState: .live).isStaleQueuedReply)
        #expect(!makeAnsweredCase(status: .waitingOnAgent, latestReplyState: .queued, sessionState: .disconnected).isStaleQueuedReply)
        #expect(!makeAnsweredCase(status: .waitingOnAgent, latestReplyState: .queued, sessionState: nil).isStaleQueuedReply)
        #expect(!makeAnsweredCase(status: .waitingOnAgent, latestReplyState: .delivered, sessionState: .ended).isStaleQueuedReply)
        #expect(!makeAnsweredCase(status: .needsYou, latestReplyState: .queued, sessionState: .ended).isStaleQueuedReply)
    }

    @Test func showsWaitingForPickupIsFalseOnceTheStaleLabelTakesOver() {
        let stale = makeAnsweredCase(status: .waitingOnAgent, latestReplyState: .queued, sessionState: .ended)
        #expect(!stale.showsWaitingForPickup(deliveryStatus: nil))
    }

    // MARK: - Detail formats (HAIL-139)

    @Test func replyFormatRowLabelsAndThreadLabels() {
        #expect(ReplyFormat.eli5.rowLabel == "Explain it like I'm five")
        #expect(ReplyFormat.diagram.rowLabel == "As a diagram")
        #expect(ReplyFormat.page.rowLabel == "As an interactive page")
        #expect(ReplyFormat.eli5.threadLabel == "like I'm five")
        #expect(ReplyFormat.diagram.threadLabel == "as a diagram")
        #expect(ReplyFormat.page.threadLabel == "as an interactive page")
        // The one-tap rows are keys 5, 6 and 7 in this order.
        #expect(ReplyFormat.allCases.map(\.rawValue) == ["eli5", "diagram", "page"])
    }
}
