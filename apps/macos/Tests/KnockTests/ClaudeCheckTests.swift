import Testing
import Foundation
@testable import Knock

// HAIL-170: "Claude is not checking" and the Copy reply line, for a session that cannot be nudged.
struct ClaudeCheckTests {
    private let sent = "2026-10-05T10:00:00.000Z"

    private func makeCase(
        canNudge: Bool? = false, runtime: Runtime = .claude, replyState: ReplyStatus? = .queued,
        lastCheckAt: String? = nil, choice: String? = "a", choices: [String] = [], message: String? = nil,
        select: Case.Select = .one, clientName: String? = nil, title: String = "Title",
        answerText: String? = nil
    ) -> Case {
        Case(
            id: "c_1", taskId: "t_1", kind: .question, title: title, need: "Need", why: "Why",
            recommendation: "a", recommendationWhy: "Because",
            options: [Option(id: "a", label: "Short"), Option(id: "b", label: "Long.", title: "Long one")],
            status: .waitingOnAgent, hasArtifact: false, latestReplyId: "r_1", latestReplyState: replyState,
            latestReplyAt: sent, latestReplyChoice: choice, latestReplyMessage: message,
            latestReplyChoices: choices, select: select, runtime: runtime, sessionState: .live,
            lastCheckAt: lastCheckAt, sessionCanNudge: canNudge, sessionClientName: clientName,
            createdAt: "2026-10-05T09:00:00.000Z", updatedAt: sent,
            latestReplyAnswerText: answerText
        )
    }

    private func at(_ seconds: TimeInterval) -> Date {
        KnockDateFormat.date(from: sent)!.addingTimeInterval(seconds)
    }

    @Test func waitingThenNotCheckingAfterTwoMinutes() {
        let item = makeCase()
        #expect(ClaudeCheck.state(for: item, now: at(5)) == .waiting)
        #expect(ClaudeCheck.state(for: item, now: at(119)) == .waiting)
        #expect(ClaudeCheck.state(for: item, now: at(120)) == .notChecking)
    }

    @Test func aCheckAfterTheAnswerKeepsItWaiting() {
        let item = makeCase(lastCheckAt: "2026-10-05T10:01:00.000Z")
        #expect(ClaudeCheck.state(for: item, now: at(300)) == .waiting)
    }

    @Test func aCheckBeforeTheAnswerDoesNotCount() {
        let item = makeCase(lastCheckAt: "2026-10-05T09:59:50.000Z")
        #expect(ClaudeCheck.state(for: item, now: at(130)) == .notChecking)
    }

    @Test func pickedUpWhenTheReplyIsAcknowledged() {
        #expect(ClaudeCheck.state(for: makeCase(replyState: .delivered), now: at(500)) == .pickedUp)
        #expect(ClaudeCheck.state(for: makeCase(), delivery: .delivered(at: at(10)), now: at(500)) == .pickedUp)
    }

    @Test func claudeCodeAndOtherCasesAreUnaffected() {
        #expect(ClaudeCheck.state(for: makeCase(canNudge: true), now: at(500)) == nil)
        #expect(ClaudeCheck.state(for: makeCase(canNudge: nil), now: at(500)) == nil)
        #expect(ClaudeCheck.state(for: makeCase(runtime: .codex), now: at(500)) == nil)
        #expect(ClaudeCheck.state(for: makeCase(replyState: .failed), now: at(500)) == nil)
    }

    @Test func replyLineForAChoice() {
        #expect(ClaudeCheck.replyLine(for: makeCase(choice: "a")) == "I answered your Waggle question: Short. Continue.")
        #expect(ClaudeCheck.replyLine(for: makeCase(choice: "b", message: "also this")) == "I answered your Waggle question: Long one. Continue.")
    }

    @Test func replyLineForSeveralChoices() {
        let item = makeCase(choice: "a", choices: ["a", "b"], select: .many)
        #expect(ClaudeCheck.replyLine(for: item) == "I answered your Waggle question: Short, Long one. Continue.")
    }

    @Test func replyLineForANoteOnly() {
        let item = makeCase(choice: nil, message: "Do it differently")
        #expect(ClaudeCheck.replyLine(for: item) == "I answered your Waggle question in Waggle. Continue.")
        #expect(!ClaudeCheck.replyLine(for: item).contains("with a note"))
        #expect(!ClaudeCheck.replyLine(for: item).contains("—"))
    }

    @Test func theSentCardIsLabelledForTheClaudeApp() {
        let answer = SentAnswerCopy.claudeApp(SentAnswerCopy.answer(for: makeCase()))
        #expect(answer.label == "YOUR ANSWER")
        #expect(ClaudeCheck.sentLine(sentAt: at(0), timeZone: TimeZone(identifier: "UTC")!) == "Sent to Claude app · 10:00")
    }

    @Test func decodesTheNewFields() throws {
        let json = #"""
        {"id":"c_1","task_id":"t_1","kind":"question","title":"T","need":"N","why":"W","recommendation":"a","recommendation_why":"b","options":[],"status":"waiting_on_agent","has_artifact":false,"last_check_at":"2026-10-05T10:01:00.000Z","session_can_nudge":false,"created_at":"2026-10-05T09:00:00.000Z","updated_at":"2026-10-05T09:00:00.000Z"}
        """#
        let item = try JSONDecoder().decode(Case.self, from: Data(json.utf8))
        #expect(item.lastCheckAt == "2026-10-05T10:01:00.000Z")
        #expect(item.sessionCanNudge == false)
    }

    // HAIL-173: the client name, the label and the one fallback.
    @Test func namesTheClient() {
        #expect(makeCase(clientName: "claude-ai").runtimeLabel == "Claude app")
        #expect(makeCase(clientName: "Claude Cowork").runtimeLabel == "Cowork")
        #expect(makeCase(clientName: "cowork").runtimeLabel == "Cowork")
        #expect(makeCase(clientName: "local-agent-mode-waggle").runtimeLabel == "Cowork")
        #expect(makeCase(clientName: "local-agent-mode-knock").runtimeLabel == "Cowork")
        #expect(makeCase(clientName: "claude-code").runtimeLabel == "Claude Code")
        #expect(makeCase(canNudge: true, clientName: "claude-ai").runtimeLabel == "Claude Code")
        #expect(makeCase(clientName: nil).runtimeLabel == "Claude Code")
        #expect(makeCase(runtime: .codex, clientName: "codex-mcp-client").runtimeLabel == "Codex")
        #expect(makeCase(clientName: "claude-ai").sessionLabel == " · Claude app")
    }

    @Test func namesTheSessionClient() {
        func session(_ name: String?, canNudge: Bool, runtime: Runtime = .claude) -> SessionInfo {
            SessionInfo(
                id: "s", runtime: runtime, taskName: "t", project: "p", branch: nil, canNudge: canNudge,
                clientName: name, state: .live, connectedAt: sent, lastSeenAt: sent)
        }
        #expect(session("claude-ai", canNudge: false).runtimeLabel == "Claude app")
        #expect(session("cowork-agent", canNudge: false).runtimeLabel == "Cowork")
        #expect(session("local-agent-mode-waggle", canNudge: false).runtimeLabel == "Cowork")
        #expect(session("claude-code", canNudge: false).runtimeLabel == "Claude Code")
        #expect(session(nil, canNudge: false).runtimeLabel == "Claude Code")
        #expect(session("codex", canNudge: false, runtime: .codex).runtimeLabel == "Codex")
    }

    @Test func decodesTheClientName() throws {
        let json = #"""
        {"id":"c_1","task_id":"t_1","kind":"question","title":"T","need":"N","why":"W","recommendation":"a","recommendation_why":"b","options":[],"status":"waiting_on_agent","has_artifact":false,"session_can_nudge":false,"session_client_name":"claude-ai","created_at":"2026-10-05T09:00:00.000Z","updated_at":"2026-10-05T09:00:00.000Z"}
        """#
        let item = try JSONDecoder().decode(Case.self, from: Data(json.utf8))
        #expect(item.sessionClientName == "claude-ai")
        #expect(item.runtimeLabel == "Claude app")
        let session = #"{"id":"s","runtime":"claude","task_name":"t","project":"p","branch":null,"can_nudge":false,"client_name":"cowork","state":"live","connected_at":"x","last_seen_at":"x"}"#
        #expect(try JSONDecoder().decode(SessionInfo.self, from: Data(session.utf8)).clientName == "cowork")
    }

    @Test func rowFallbackPerRuntime() {
        // Claude app and Cowork: Copy reply after 2 minutes, never before.
        for name in ["claude-ai", "Claude Cowork", nil] {
            let item = makeCase(clientName: name)
            #expect(PickupFallback.kind(for: item, now: at(119)) == .none)
            #expect(PickupFallback.kind(for: item, now: at(120)) == .copyReply)
        }
        // Claude Code (nudgeable, or named claude-code): the old prompt.
        #expect(PickupFallback.kind(for: makeCase(canNudge: true), now: at(120)) == .copyPrompt(.live))
        #expect(PickupFallback.kind(for: makeCase(clientName: "claude-code"), now: at(120)) == .copyPrompt(.live))
        #expect(PickupFallback.kind(for: makeCase(clientName: "claude-code"), now: at(5)) == .none)
        // Codex: the old prompt.
        #expect(PickupFallback.kind(for: makeCase(runtime: .codex), now: at(120)) == .copyPrompt(.live))
        // A check after the answer keeps the Claude app quiet.
        let checked = makeCase(lastCheckAt: "2026-10-05T10:01:00.000Z", clientName: "claude-ai")
        #expect(PickupFallback.kind(for: checked, now: at(300)) == .none)
    }

    @Test func theReplyLineAndConfirmation() {
        #expect(ClaudeCheck.replyLine(for: makeCase(clientName: "claude-ai")) == "I answered your Waggle question: Short. Continue.")
        #expect(ClaudeCheck.copiedLine(for: makeCase(clientName: nil)) == "Copied. Paste it in your Claude chat or Cowork task.")
        #expect(ClaudeCheck.copiedLine(for: makeCase(clientName: "claude-ai")) == "Copied. Paste it in the Claude chat.")
        #expect(ClaudeCheck.copiedLine(for: makeCase(clientName: "local-agent-mode-waggle")) == "Copied. Paste it in your Cowork task.")
        #expect(ClaudeCheck.notCheckingBody(for: makeCase(clientName: "local-agent-mode-knock")).contains("Cowork task"))
        #expect(ClaudeCheck.notCheckingShort == "Claude is not checking")
        #expect(ClaudeCheck.copyReplyLabel == "Copy answer")
        #expect(PickupFallback.copiedLine(runtime: "Claude Code") == "Copied. Paste it in the Claude Code terminal.")
    }

    // MARK: The standalone paste (WAG-295)

    private let hint = "If your Waggle tools are connected, call waggle_check with this case_id to mark it delivered."

    @Test func theStandaloneAnswerForChoicesOnly() {
        let body = "Choices: a, b\n- a: Short\n- b: Long one"
        let item = makeCase(choice: nil, choices: ["a", "b"], select: .many, answerText: body)
        #expect(ClaudeCheck.standaloneAnswer(for: item) == "My Waggle answer to \"Title\" (case c_1):\n\(body)\n\(hint)")
    }

    @Test func theStandaloneAnswerForANoteOnly() {
        let item = makeCase(choice: nil, answerText: "Message: Neither, try a table")
        let text = ClaudeCheck.standaloneAnswer(for: item)
        #expect(text == "My Waggle answer to \"Title\" (case c_1):\nMessage: Neither, try a table\n\(hint)")
        #expect(!text.contains("with a note"))
    }

    @Test func theStandaloneAnswerForSeveralQuestionsKeepsPointsAndNotes() {
        let body = "Answers:\nQ1 · point 1: Three · note: keep it simple\nQ2 · point 1: Yes"
        let item = makeCase(choice: nil, answerText: body + "\n")
        let lines = ClaudeCheck.standaloneAnswer(for: item).components(separatedBy: "\n")
        #expect(lines.first == "My Waggle answer to \"Title\" (case c_1):")
        #expect(lines.dropFirst().dropLast().joined(separator: "\n") == body)
        #expect(lines.last == hint)
        #expect(!ClaudeCheck.standaloneAnswer(for: item).contains("\u{2014}"))
    }

    @Test func aMissingTitleLeavesItOut() {
        let item = makeCase(title: "  ", answerText: "Choice: a (Short)")
        #expect(ClaudeCheck.standaloneAnswer(for: item) == "My Waggle answer (case c_1):\nChoice: a (Short)\n\(hint)")
    }

    @Test func withoutDaemonTextTheBodyFallsBackToTheChoiceLine() {
        let text = ClaudeCheck.standaloneAnswer(for: makeCase(choice: "a"))
        #expect(text == "My Waggle answer to \"Title\" (case c_1):\nI answered your Waggle question: Short. Continue.\n\(hint)")
    }
}
