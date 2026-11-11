import AppKit
import Foundation
import Testing
@testable import Knock

/// The status line (C10, spec 2026-11-09 section 8): each state is one line in the context line, with a button
/// only when there is something to do; a failed delivery is red, readable in full, and stays until Retry works or
/// it is hidden.
@MainActor
struct RequestStatusTests {
    private let at = "2026-11-09T10:00:00Z"

    private func item(
        status: CaseStatus = .waitingOnAgent, kind: Case.Kind = .question, session: SessionState? = .live,
        replyState: ReplyStatus? = .queued, doneAt: String? = nil, endedAt: String? = nil
    ) -> Case {
        Case(
            id: "c_1", taskId: "t_1", kind: kind, title: "Pick a layout", need: "Need", why: "Why", recommendation: "a",
            recommendationWhy: "Because", options: [Option(id: "a", label: "Compact")], status: status,
            hasArtifact: false, latestReplyId: replyState == nil ? nil : "reply_1", latestReplyState: replyState,
            latestReplyAt: replyState == nil ? nil : at, sessionState: session, doneAt: doneAt, sessionEndedAt: endedAt,
            createdAt: at, updatedAt: at)
    }

    private func line(_ input: RequestStatus.Input) -> RequestStatus.Line? { RequestStatus.line(input) }

    // MARK: - Each state, its words and its buttons

    @Test func anOpenAskWithNothingToSayHasNoLine() {
        #expect(line(.init(item: item(status: .needsYou, replyState: nil))) == nil)
    }

    @Test func offlineSaysOfflineWithNoButton() {
        let offline = line(.init(item: item(status: .needsYou, replyState: nil), isOffline: true))
        #expect(offline?.kind == .offline)
        #expect(offline?.text == "Offline")
        #expect(offline?.actions == [])
        #expect(offline?.help == RequestStatus.offlineHelp)
    }

    @Test func doneHasGotIt() {
        let done = line(.init(item: item(replyState: .delivered, doneAt: at)))
        #expect(done?.kind == .done)
        #expect(done?.text.hasPrefix("Done · ") == true)
        #expect(done?.actions == [.gotIt])
        #expect(done?.tone == .ok)
    }

    @Test func sendingHasNoButton() {
        let sending = line(.init(item: item(status: .needsYou, replyState: nil), local: .sending))
        #expect(sending?.text == "Sending your answer")
        #expect(sending?.actions == [])
    }

    @Test func sentWaitsWithChangeAnswerAndTheFallbackMenu() {
        let queued = item()
        let sent = line(.init(item: queued, pickup: .copyPrompt(.live)))
        #expect(sent?.kind == .sent)
        #expect(sent?.text == "Sent · waiting for the agent")
        #expect(sent?.actions == [.changeAnswer])
        #expect(sent?.hasMoreMenu == true)
        // Before the 2 minutes, no fallback.
        #expect(line(.init(item: queued))?.hasMoreMenu == false)
        // A review also opens the review workspace.
        #expect(line(.init(item: item(kind: .review)))?.actions == [.changeAnswer, .openReview])
    }

    @Test func workingShowsTheAgentAndWhenItRead() {
        let read = Date(timeIntervalSince1970: 1_700_000_000)
        let working = line(.init(
            item: item(replyState: .delivered), confirmed: .delivered(at: read), readAt: read))
        #expect(working?.kind == .working)
        #expect(working?.text.hasSuffix("is working on your reply") == true)
        #expect(working?.meta?.hasPrefix("read at ") == true)
        #expect(working?.actions == [])
        // A delivered review keeps its way back to the review.
        #expect(line(.init(item: item(kind: .review, replyState: .delivered)))?.actions == [.viewReview])
    }

    @Test func aSettledAnswerOpensItsFollowUp() {
        let settled = AnswerGrouping.Settled(pickedUpAt: nil, followUp: .init(id: "c_2", title: "Next step"))
        let done = line(.init(item: item(replyState: .delivered), settled: settled))
        #expect(done?.kind == .settled)
        #expect(done?.text == "Not picked up")
        #expect(done?.actions == [.openFollowUp(caseId: "c_2")])
        #expect(done?.actions.first?.label == "Open the follow-up")
    }

    @Test func aDeliveredAnswerSaysDelivered() {
        let delivered = line(.init(
            item: item(status: .resolved, replyState: .delivered), confirmed: .delivered(at: Date())))
        #expect(delivered?.kind == .delivered)
        #expect(delivered?.text.hasPrefix("Delivered ✓") == true)
        #expect(delivered?.actions == [.copyAnswer])
        let review = line(.init(
            item: item(status: .resolved, kind: .review, replyState: .delivered), confirmed: .delivered(at: Date())))
        #expect(review?.actions == [.copyAnswer, .viewReview])
    }

    @Test func aClosedSessionBeforeTheAnswerOffersANewSession() {
        let closed = line(.init(item: item(status: .needsYou, session: .ended, replyState: nil)))
        #expect(closed?.kind == .sessionClosed)
        #expect(closed?.text == "Session closed")
        #expect(closed?.reason == SessionClosedCopy.notice)
        #expect(closed?.actions == [.continueInNewSession])
    }

    @Test func aClosedSessionWhileTheReplyWaitsOffersTheAnswerAndANewSession() {
        let closed = line(.init(item: item(session: .ended), pickup: .copyPrompt(.closed)))
        #expect(closed?.kind == .closed)
        #expect(closed?.actions == [.copyAnswer, .continueInNewSession])
        #expect(closed?.hasMoreMenu == true)
        // After the agent read it there is nothing to redo.
        let read = line(.init(item: item(session: .ended, replyState: .delivered)))
        #expect(read?.actions == [])
    }

    @Test func notDeliveredIsRedWithItsReasonRetryAndHide() {
        let failed = line(.init(item: item(session: .disconnected, replyState: .failed), confirmed: .failed(replyId: "reply_1")))
        #expect(failed?.kind == .notDelivered)
        #expect(failed?.text == "Not delivered")
        #expect(failed?.reason == RequestStatus.unreachable)
        #expect(failed?.tone == .failed)
        #expect(failed?.actions == [.retry])
        #expect(failed?.canHide == true)
        #expect(failed?.help == "reply reply_1")
    }

    @Test func aFailedReplyOfASessionThatCameBackWaitsForTheNextCheck() {
        let back = line(.init(item: item(session: .live, replyState: .failed), confirmed: .failed(replyId: "reply_1")))
        #expect(back?.kind == .saved)
        #expect(back?.text == SessionClosedCopy.resumedTitle)
        #expect(back?.tone == .agent(.waitingForPickup))
        #expect(back?.actions == [.retry])
        // The page's own send that failed just now stays a red failure.
        let now = line(.init(item: item(session: .live, replyState: .failed), local: .failed(replyId: "reply_1")))
        #expect(now?.kind == .notDelivered)
        #expect(now?.tone == .failed)
    }

    @Test func aClosedSessionsSaveIsRed() {
        let saved = line(.init(item: item(session: .ended, replyState: .failed)))
        #expect(saved?.kind == .saved)
        #expect(saved?.tone == .failed)
    }

    @Test func refusedKeepsTheServicesReasonInFull() {
        let reason = "The case was dismissed in another window, so the service cannot take a reply for it any more."
        let refused = line(.init(item: item(status: .needsYou, replyState: nil), local: .refused(reason: reason)))
        #expect(refused?.text == "Not delivered")
        #expect(refused?.reason?.contains(reason) == true)
        #expect(refused?.tone == .failed)
        #expect(refused?.actions == [.retry])
    }

    @Test func notSentWhileTheServiceIsOffline() {
        let offline = line(.init(item: item(status: .needsYou, replyState: nil), local: .offline))
        #expect(offline?.kind == .notSent)
        #expect(offline?.text == "Not sent")
        #expect(offline?.reason?.contains(RequestStatus.savedOnMac) == true)
        #expect(offline?.actions == [.retry])
    }

    @Test func aHiddenFailureShowsNothingButAClosedSessionsSaveIsNotHideable() {
        let failed = RequestStatus.Input(item: item(replyState: .failed), confirmed: .failed(replyId: "reply_1"), isHidden: true)
        #expect(line(failed) == nil)
        let saved = line(.init(item: item(session: .ended, replyState: .failed), isHidden: true))
        #expect(saved?.kind == .saved)
        #expect(saved?.actions == [.copyAnswer, .continueInNewSession])
        #expect(saved?.canHide == false)
    }

    @Test func aFailureOfAnEarlierRoundDoesNotShowOnANewRound() {
        // The model still holds the old outcome while the case needs you again.
        #expect(line(.init(item: item(status: .needsYou, replyState: nil), confirmed: .failed(replyId: "old"))) == nil)
    }

    @Test func changingTheAnswerHidesTheLine() {
        #expect(line(.init(item: item(), isEditingLockedAnswer: true)) == nil)
    }

    @Test func theHandedOverReplyIsACalmLine() {
        let handed = line(.init(item: item(status: .resolved, replyState: .handedOver)))
        #expect(handed?.kind == .handedOver)
        #expect(handed?.actions == [])
    }

    @Test func fullSizeKeepsOnlyTheButtonsItCanWire() {
        let saved = line(.init(item: item(session: .ended, replyState: .failed)))
        #expect(saved?.keeping(only: [.retry, .copyAnswer]).actions == [.copyAnswer])
    }

    @Test func theComposersOwnSendHasItsLine() {
        let open = item(status: .needsYou, replyState: nil)
        #expect(RequestStatus.localLine(.idle, item: open) == nil)
        #expect(RequestStatus.localLine(.sending, item: open)?.kind == .sending)
        #expect(RequestStatus.localLine(.sent, item: open)?.kind == .sent)
        #expect(RequestStatus.localLine(.refused(reason: "No"), item: open)?.tone == .failed)
    }

    @Test func theHideKeyIsPerCaseAndShowsAgainAfterRetry() {
        let store = HiddenStatusStore()
        let failed = try! #require(line(.init(item: item(replyState: .failed), confirmed: .failed(replyId: "reply_1"))))
        let key = HiddenStatusStore.key(caseId: "c_1", line: failed)
        store.hide(key)
        #expect(store.isHidden(key))
        #expect(!store.isHidden(HiddenStatusStore.key(caseId: "c_2", line: failed)))
        store.showAgain(caseId: "c_1")
        #expect(!store.isHidden(key))
    }

    @Test func aHiddenFailureShowsAgainWhenTheNextFailureHasTheSameReason() {
        let store = HiddenStatusStore()
        let offline = try! #require(line(.init(item: item(replyState: .failed), local: .offline)))
        let key = HiddenStatusStore.key(caseId: "c_1", line: offline)
        store.hide(key)
        store.follow(caseId: "c_1", failing: true)
        #expect(store.isHidden(key))
        store.follow(caseId: "c_1", failing: false)
        #expect(!store.isHidden(key))
    }

    // MARK: - Contrast of the failed line, light and dark (WCAG 2.x, at least 4.5:1)

    private func resolved(_ color: NSColor, _ name: NSAppearance.Name) -> NSColor {
        var out = color
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB)!
        }
        return out
    }

    private func luminance(_ color: NSColor) -> Double {
        func channel(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent) + 0.7152 * channel(color.greenComponent) + 0.0722 * channel(color.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    @Test func theFailedTextReadsAtFourPointFiveToOneInLightAndDark() {
        for name: NSAppearance.Name in [.aqua, .darkAqua] {
            let text = resolved(StatusLineColors.failedText, name)
            let fill = resolved(StatusLineColors.failedFill, name)
            #expect(contrast(text, fill) >= 4.5, "\(name.rawValue): \(contrast(text, fill))")
        }
        // The light pair also reads on the page's white, and is not the brand red (4.45:1 on white).
        let light = resolved(StatusLineColors.failedText, .aqua)
        #expect(contrast(light, StatusLineColors.srgb(0xFFFFFF)) >= 4.5)
        #expect(contrast(StatusLineColors.srgb(0xE0352B), StatusLineColors.srgb(0xFFFFFF)) < 4.5)
        // The two appearances get their own colors.
        #expect(resolved(StatusLineColors.failedText, .darkAqua) != light)
    }
}
