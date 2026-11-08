import Foundation
import SwiftUI
import Testing
@testable import Knock

/// HAIL-62 / HAIL-66: the status mapping, the pixel patterns, the timer text
/// and the footer rule.
struct AgentStatusTests {
    private func ask(
        _ id: String = "a", taskId: String = "t1", status: CaseStatus, replyState: ReplyStatus? = nil,
        intent: ReplyIntent? = nil, sessionState: SessionState? = .live, createdAt: String = "2026-09-29T11:00:00Z",
        replyAt: String? = nil, deliveredAt: String? = nil
    ) -> Case {
        Case(
            id: id, taskId: taskId, kind: .question, title: "T", need: "N", why: "W", recommendation: "R",
            recommendationWhy: "RW", options: [], status: status, hasArtifact: false,
            latestReplyState: replyState, latestReplyAt: replyAt, latestReplyDeliveredAt: deliveredAt, latestReplyIntent: intent, sessionState: sessionState,
            createdAt: createdAt, updatedAt: createdAt
        )
    }

    private func session(state: SessionState = .live, taskId: String = "t1") -> SessionInfo {
        SessionInfo(
            id: "s", taskId: taskId, runtime: .claude, taskName: "main", project: "knock", branch: "main",
            cwd: "/tmp", state: state, connectedAt: "2026-09-29T09:00:00Z", lastSeenAt: "2026-09-29T11:00:00Z"
        )
    }

    // MARK: Case mapping

    @Test func aCaseThatNeedsYouIsNeedsYou() {
        #expect(AgentStatus.forCase(ask(status: .needsYou)) == .needsYou)
    }

    @Test func aQueuedReplyIsWaitingForPickup() {
        #expect(AgentStatus.forCase(ask(status: .waitingOnAgent, replyState: .queued)) == .waitingForPickup)
        #expect(AgentStatus.forCase(ask(status: .waitingOnAgent)) == .waitingForPickup)
    }

    @Test func aDeliveredReplyIsWorking() {
        #expect(AgentStatus.forCase(ask(status: .waitingOnAgent, replyState: .delivered, intent: .decision)) == .working)
    }

    @Test func aDeliveredAskForMoreDetailIsWritingToYou() {
        #expect(AgentStatus.forCase(ask(status: .waitingOnAgent, replyState: .delivered, intent: .moreDetail)) == .writingToYou)
    }

    @Test func aQueuedAskForMoreDetailIsStillWaitingForPickup() {
        #expect(AgentStatus.forCase(ask(status: .waitingOnAgent, replyState: .queued, intent: .moreDetail)) == .waitingForPickup)
    }

    @Test func aLiveDeliveryEventBeatsAStaleRow() {
        let item = ask(status: .waitingOnAgent, replyState: .queued)
        #expect(AgentStatus.forCase(item, deliveryStatus: .delivered(at: Date())) == .working)
    }

    @Test func anEndedOrUnreachableSessionIsClosed() {
        #expect(AgentStatus.forCase(ask(status: .waitingOnAgent, replyState: .queued, sessionState: .ended)) == .closed)
        #expect(AgentStatus.forCase(ask(status: .waitingOnAgent, replyState: .delivered, sessionState: .disconnected)) == .closed)
    }

    @Test func aCaseThatNeedsYouStaysNeedsYouEvenIfTheSessionEnded() {
        #expect(AgentStatus.forCase(ask(status: .needsYou, sessionState: .ended)) == .needsYou)
    }

    // MARK: Session mapping

    @Test func aSessionWithANeedsYouAskIsNeedsYou() {
        let cases = [ask("a", status: .waitingOnAgent, replyState: .delivered), ask("b", status: .needsYou)]
        #expect(AgentStatus.forSession(session(), cases: cases) == .needsYou)
    }

    @Test func aSessionTakesTheStateOfItsNewestWaitingAsk() {
        let cases = [
            ask("old", status: .waitingOnAgent, replyState: .queued, createdAt: "2026-09-29T10:00:00Z"),
            ask("new", status: .waitingOnAgent, replyState: .delivered, createdAt: "2026-09-29T11:00:00Z"),
        ]
        #expect(AgentStatus.forSession(session(), cases: cases) == .working)
        let reversed = [
            ask("old", status: .waitingOnAgent, replyState: .delivered, createdAt: "2026-09-29T10:00:00Z"),
            ask("new", status: .waitingOnAgent, replyState: .queued, createdAt: "2026-09-29T11:00:00Z"),
        ]
        #expect(AgentStatus.forSession(session(), cases: reversed) == .waitingForPickup)
    }

    @Test func aLiveSessionWithNoAsksIsConnectedAndAnEndedOneIsClosed() {
        #expect(AgentStatus.forSession(session(), cases: []) == .connected)
        #expect(AgentStatus.forSession(session(state: .ended), cases: []) == .closed)
        #expect(AgentStatus.forSession(session(state: .disconnected), cases: []) == .closed)
    }

    @Test func otherTasksAsksDoNotCount() {
        #expect(AgentStatus.forSession(session(), cases: [ask(taskId: "other", status: .needsYou)]) == .connected)
    }

    // MARK: Pixel patterns

    @Test func driveDelaysFormAChevron() {
        let p = PixelPattern.drive
        // (column + |row - 1|) x 90 ms
        #expect(abs(p.delay(cell: 0) - 0.09) < 1e-9)   // r0 c0
        #expect(abs(p.delay(cell: 3) - 0.0) < 1e-9)    // r1 c0
        #expect(abs(p.delay(cell: 5) - 0.18) < 1e-9)   // r1 c2
        #expect(abs(p.delay(cell: 8) - 0.27) < 1e-9)   // r2 c2
        #expect(p.duration == 0.65)
    }

    @Test func orbitWalksTheEdgeAndHoldsTheCentre() {
        let p = PixelPattern.orbit
        let order = [0, 1, 2, 5, 8, 7, 6, 3]
        for (step, cell) in order.enumerated() {
            #expect(abs(p.delay(cell: cell) - Double(step) * 0.11) < 1e-9)
        }
        #expect(p.duration == 0.95)
        #expect(p.opacity(cell: 4, at: 0.3) == 0.07)
        #expect(p.opacity(cell: 4, at: nil) == 0.07)
    }

    @Test func opacityRunsFromBaseToPeakAndBack() {
        let p = PixelPattern.drive
        // Cell 3 has no delay: dim at 0, full at half the pulse, dim again after one.
        #expect(p.opacity(cell: 3, at: 0) == 0.15)
        #expect(abs(p.opacity(cell: 3, at: 0.325) - 1) < 1e-9)
        #expect(abs(p.opacity(cell: 3, at: 0.65) - 0.15) < 1e-9)
        // Eased: a quarter of the way is half way up.
        #expect(abs(p.opacity(cell: 3, at: 0.1625) - 0.575) < 1e-9)
        // A delayed cell is dim until its delay has passed.
        #expect(p.opacity(cell: 8, at: 0.2) == 0.15)
        #expect(p.opacity(cell: 8, at: 0.27 + 0.325) > 0.99)
        // Loops.
        #expect(abs(p.opacity(cell: 3, at: 0.325 + 0.65 * 4) - 1) < 1e-9)
    }

    @Test func aFrozenPatternIsDim() {
        for pattern in [PixelPattern.drive, .dots(duration: 1.3)] {
            for cell in 0..<9 { #expect(pattern.opacity(cell: cell, at: nil) == 0.15) }
        }
    }

    @Test func aStillPatternHasOneOpacityAtAnyTime() {
        let p = PixelPattern.still(0.28)
        #expect(!p.isAnimated)
        for cell in 0..<9 {
            #expect(p.opacity(cell: cell, at: nil) == 0.28)
            #expect(p.opacity(cell: cell, at: 12.3) == 0.28)
        }
    }

    @Test func onlyDotsAreRoundAndTheGridGeometryFollowsTheCell() {
        #expect(PixelPattern.dots().isRound)
        #expect(!PixelPattern.drive.isRound && !PixelPattern.orbit.isRound)
        #expect(PixelPattern.dots(duration: 1.3).duration == 1.3)
        // 3 cells and 2 gaps of 0.375 x cell.
        #expect(abs(PixelStatusGrid.side(cell: 4) - 15) < 1e-9)
        #expect(abs(PixelStatusGrid.side(cell: 3) - 11.25) < 1e-9)
    }

    @Test func statusesUseTheirPatterns() {
        #expect(AgentStatus.needsYou.pattern == .still(0.9))
        #expect(AgentStatus.waitingForPickup.pattern == .dots(duration: 1.3))
        #expect(AgentStatus.working.pattern == .drive)
        #expect(AgentStatus.writingToYou.pattern == .orbit)
        #expect(AgentStatus.connected.pattern == .still(0.28))
        #expect(AgentStatus.closed.pattern == .still(0.12))
        #expect(AgentStatus.allCases.filter(\.shimmers) == [.working, .writingToYou])
    }

    // MARK: Timer text

    @Test func elapsedTextUnderAMinuteIsWholeSeconds() {
        #expect(ElapsedFormat.string(seconds: 0) == "0s")
        #expect(ElapsedFormat.string(seconds: 12.34) == "12s")
        #expect(ElapsedFormat.string(seconds: 59.99) == "59s")
        #expect(ElapsedFormat.string(seconds: -3) == "0s")
    }

    @Test func elapsedTextThenShowsMinutesAndHours() {
        #expect(ElapsedFormat.string(seconds: 60) == "1m 0s")
        #expect(ElapsedFormat.string(seconds: 96.4) == "1m 36s")
        #expect(ElapsedFormat.string(seconds: 3599.9) == "59m 59s")
        #expect(ElapsedFormat.string(seconds: 3600) == "1h 0m")
        #expect(ElapsedFormat.string(seconds: 3600 + 4 * 60 + 30) == "1h 4m")
    }

    @Test func theShimmerSweepLoopsEvery1_4Seconds() {
        #expect(ShimmerLabel.sweep(at: 0) == 0)
        #expect(abs(ShimmerLabel.sweep(at: 0.7) - 0.5) < 1e-9)
        #expect(abs(ShimmerLabel.sweep(at: 1.4 + 0.35) - 0.25) < 1e-9)
    }

    // MARK: Footer

    @Test func theFooterShowsTheBusiestState() {
        #expect(AgentStatus.busiest([.connected, .waitingForPickup, .writingToYou, .working]) == .working)
        #expect(AgentStatus.busiest([.connected, .waitingForPickup, .writingToYou]) == .writingToYou)
        #expect(AgentStatus.busiest([.connected, .waitingForPickup, .needsYou]) == .waitingForPickup)
        #expect(AgentStatus.busiest([.needsYou, .closed, .connected]) == .connected)
        #expect(AgentStatus.busiest([]) == .connected)
    }

    @Test func theFooterCountsWorkingAndWritingSessions() {
        #expect(AgentStatus.workingCount([.working, .writingToYou, .waitingForPickup, .connected]) == 2)
        #expect(AgentStatus.workingCount([]) == 0)
    }

    // MARK: Timer start

    @Test func theTimerStartsAtPickupOrSend() {
        let item = ask(
            status: .waitingOnAgent, replyState: .delivered,
            replyAt: "2026-09-29T11:00:00Z", deliveredAt: "2026-09-29T11:00:30Z")
        let picked = KnockDateFormat.date(from: "2026-09-29T11:00:30Z")!
        let sent = KnockDateFormat.date(from: "2026-09-29T11:00:00Z")!
        #expect(AgentStatus.timerStart(item, status: .working, deliveryStatus: nil) == picked)
        #expect(AgentStatus.timerStart(item, status: .waitingForPickup, deliveryStatus: nil) == sent)
        #expect(AgentStatus.timerStart(item, status: .needsYou, deliveryStatus: nil) == nil)
        #expect(AgentStatus.timerStart(item, status: .closed, deliveryStatus: nil) == nil)
        let live = Date(timeIntervalSinceReferenceDate: 5)
        #expect(AgentStatus.timerStart(item, status: .working, deliveryStatus: .delivered(at: live)) == live)
    }

    // MARK: Strip copy

    @Test func theStripCopyIsPlainAndHasNoEmDashes() {
        let expected: [AgentStatus: String] = [
            .working: "Claude Code is working on your reply",
            .waitingForPickup: "Claude Code has not picked up your reply yet",
            .writingToYou: "Claude Code is writing the detail you asked for",
            .closed: "The session closed before it read your reply",
        ]
        for (status, text) in expected {
            #expect(AgentStatusCopy.headline(status: status, runtime: "Claude Code") == text)
            #expect(!text.contains("\u{2014}"))
        }
        #expect(AgentStatusCopy.headline(status: .needsYou, runtime: "Codex") == nil)
        for status in AgentStatus.allCases {
            #expect(!status.label.contains("\u{2014}") && !status.shortLabel.contains("\u{2014}"))
        }
        #expect(AgentStatus.waitingForPickup.shortLabel == "Not picked up")
        #expect(AgentStatus.working.shortLabel == AgentStatus.working.label)
    }

    @Test func theStripSaysWhenTheAgentReadTheReply() {
        let utc = TimeZone(identifier: "UTC")!
        let read = KnockDateFormat.date(from: "2026-09-29T16:05:09Z")!
        #expect(AgentStatusCopy.readLine(readAt: read, timeZone: utc) == "read at 16:05")
        #expect(AgentStatusCopy.readLine(readAt: nil, timeZone: utc) == nil)
    }
}
