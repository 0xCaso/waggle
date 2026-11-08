import AppKit
import Testing
import Foundation
@testable import Knock

// HAIL-76: the fallback for a reply the agent has not picked up.
struct PickupFallbackTests {
    private let sent = "2026-09-30T10:00:00.000Z"

    private func makeCase(
        status: CaseStatus = .waitingOnAgent, replyState: ReplyStatus? = .queued,
        replyAt: String? = "2026-09-30T10:00:00.000Z", sessionState: SessionState? = .live
    ) -> Case {
        Case(
            id: "c_1", taskId: "t_1", kind: .question, title: "Title",
            need: "Need", why: "Why", recommendation: "a",
            recommendationWhy: "Because", options: [], status: status,
            hasArtifact: false, latestReplyId: "r_1", latestReplyState: replyState, latestReplyAt: replyAt,
            sessionState: sessionState,
            createdAt: "2026-09-30T09:00:00.000Z", updatedAt: "2026-09-30T10:00:00.000Z"
        )
    }

    private func at(_ seconds: TimeInterval) -> Date {
        KnockDateFormat.date(from: sent)!.addingTimeInterval(seconds)
    }

    // The 2 minute threshold.
    @Test func hiddenUnderTwoMinutes() {
        #expect(PickupFallback.mode(for: makeCase(), now: at(0)) == .none)
        #expect(PickupFallback.mode(for: makeCase(), now: at(119)) == .none)
    }

    @Test func showsFromTwoMinutes() {
        #expect(PickupFallback.mode(for: makeCase(), now: at(120)) == .live)
        #expect(PickupFallback.mode(for: makeCase(), now: at(3600)) == .live)
    }

    /// The strip reads "Closed" for a session that is not live (`AgentStatus.forCase`),
    /// so a disconnected session gets the closed variant too, not "It may have
    /// stopped to wait" under a banner that says the session closed (HAIL-76 captures).
    @Test func disconnectedSessionShowsTheClosedVariantLikeTheStrip() {
        #expect(PickupFallback.mode(for: makeCase(sessionState: .disconnected), now: at(5)) == .closed)
        #expect(AgentStatus.forCase(makeCase(sessionState: .disconnected)) == .closed)
    }

    @Test func endedSessionShowsTheClosedVariantAtOnce() {
        #expect(PickupFallback.mode(for: makeCase(sessionState: .ended), now: at(5)) == .closed)
    }

    @Test func nothingForAPickedUpOrMissingReply() {
        #expect(PickupFallback.mode(for: makeCase(replyState: .delivered), now: at(600)) == .none)
        #expect(PickupFallback.mode(for: makeCase(replyState: .failed), now: at(600)) == .none)
        #expect(PickupFallback.mode(for: makeCase(replyState: nil, replyAt: nil), now: at(600)) == .none)
        #expect(PickupFallback.mode(for: makeCase(status: .needsYou), now: at(600)) == .none)
        #expect(PickupFallback.mode(for: makeCase(status: .resolved), now: at(600)) == .none)
    }

    // Copy.
    @Test func promptAndCopy() {
        #expect(PickupFallback.prompt == "Check Waggle for my reply")
        #expect(PickupFallback.helpLine(mode: .none, runtime: "Claude Code") == nil)
        #expect(PickupFallback.helpLine(mode: .live, runtime: "Claude Code")
            == "It may have stopped to wait. Paste this line in its terminal:")
        #expect(PickupFallback.helpLine(mode: .closed, runtime: "Codex")
            == "Start Codex again in this project and paste this line:")
        #expect(PickupFallback.copiedLine(runtime: "Claude Code") == "Copied. Paste it in the Claude Code terminal.")
    }

    @Test func copyPromptWritesTheLineToAPasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("knock.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(PickupFallback.copyPrompt(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "Check Waggle for my reply")
    }

    // Show the terminal: the process tree walk.
    @Test func findsTheFirstRegularAppAbovetheAgent() {
        // 500 claude -> 400 zsh -> 300 login -> 200 Terminal -> 1 launchd
        let parents = [500: 400, 400: 300, 300: 200, 200: 1]
        let found = TerminalLocator.appPid(startingAt: 500, parentOf: { parents[$0] }, isApp: { $0 == 200 })
        #expect(found == 200)
    }

    @Test func findsNoAppForATmuxServerChain() {
        let parents = [500: 400, 400: 1]
        #expect(TerminalLocator.appPid(startingAt: 500, parentOf: { parents[$0] }, isApp: { _ in false }) == nil)
    }

    @Test func stopsOnAGoneProcessAndOnALoop() {
        #expect(TerminalLocator.appPid(startingAt: 500, parentOf: { _ in nil }, isApp: { _ in false }) == nil)
        #expect(TerminalLocator.appPid(startingAt: 500, parentOf: { $0 == 500 ? 400 : 500 }, isApp: { _ in false }) == nil)
    }

    @Test func realParentPidWalkReachesOurOwnParent() {
        let mine = Int(ProcessInfo.processInfo.processIdentifier)
        #expect(TerminalLocator.parentPid(of: mine) == Int(getppid()))
        #expect(TerminalLocator.parentPid(of: 999_999) == nil)
    }

    // SessionInfo.pid decodes, and an older daemon without it still decodes.
    @Test func sessionInfoDecodesPid() throws {
        let base = #"{"id":"s_1","runtime":"claude","task_name":"t","project":"p","branch":null,"state":"live","connected_at":"2026-09-30T10:00:00Z","last_seen_at":"2026-09-30T10:00:00Z""#
        let withPid = try JSONDecoder().decode(SessionInfo.self, from: Data((base + #","pid":4242}"#).utf8))
        #expect(withPid.pid == 4242)
        let without = try JSONDecoder().decode(SessionInfo.self, from: Data((base + "}").utf8))
        #expect(without.pid == nil)
    }
}
