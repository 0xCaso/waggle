import Testing
import Foundation
@testable import Knock

// WAG-410: a case whose agent session ended can continue in a new session. Nothing starts without a click.
@MainActor
struct ContinueInNewSessionTests {
    final class FakeStarter: SessionStarting {
        var calls: [(prompt: String, folder: URL, topic: String)] = []
        var succeeds = true
        func start(prompt text: String, folder: URL, topic: String) async -> Bool {
            calls.append((text, folder, topic))
            return succeeds
        }
    }

    private func makeCase(replyText: String? = nil, session: SessionState? = .ended) -> Case {
        Case(
            id: "c_1", taskId: "t_1", kind: .question, title: "Pick a layout",
            need: "Which layout ships?", why: "Why", recommendation: "a",
            recommendationWhy: "Because",
            options: [Option(id: "a", label: "Compact list", title: "Compact"), Option(id: "b", label: "Roomy cards", title: "Roomy")],
            status: replyText == nil ? .needsYou : .waitingOnAgent, hasArtifact: false,
            latestReplyId: replyText == nil ? nil : "r_1", latestReplyState: replyText == nil ? nil : .failed,
            sessionState: session,
            createdAt: "2026-10-27T09:00:00Z", updatedAt: "2026-10-27T09:00:00Z", latestReplyAnswerText: replyText)
    }

    private func session(_ id: String, task: String = "t_1", cwd: String, at: String) -> SessionInfo {
        SessionInfo(
            id: id, taskId: task, runtime: .claude, taskName: "main", project: "waggle", branch: "main",
            cwd: cwd, state: .ended, connectedAt: at, lastSeenAt: at)
    }

    @Test func promptCarriesQuestionOptionsAndAnswer() {
        let prompt = ContinuePrompt.build(for: makeCase(), answer: "Compact: Compact list")
        #expect(prompt.contains("Pick a layout"))
        #expect(prompt.contains("- Compact: Compact list"))
        #expect(prompt.contains("- Roomy: Roomy cards"))
        #expect(prompt.contains("My answer:\nCompact: Compact list"))
        #expect(!prompt.contains("—"))
    }

    @Test func aFailedReplyIsSentOnInThePrompt() {
        let prompt = ContinuePrompt.build(for: makeCase(replyText: "Roomy, please."), answer: nil)
        #expect(prompt.contains("My answer:\nRoomy, please."))
    }

    @Test func withNoAnswerThePromptAsksAgain() {
        #expect(ContinuePrompt.build(for: makeCase(), answer: "  ").contains("I have not answered yet"))
    }

    @Test func draftAnswerJoinsPicksAndNote() {
        let item = makeCase()
        #expect(ContinuePrompt.draftAnswer(options: item.options, selectedIds: ["b"], note: " soon ") == "Roomy: Roomy cards\nsoon")
        #expect(ContinuePrompt.draftAnswer(options: item.options, selectedIds: [], note: "") == nil)
    }

    @Test func folderIsTheNewestSessionOfTheTask() {
        let sessions = [
            session("s1", cwd: "/old", at: "2026-10-27T08:00:00Z"),
            session("s2", cwd: "/new", at: "2026-10-27T09:00:00Z"),
            session("s3", task: "t_2", cwd: "/other", at: "2026-10-27T10:00:00Z"),
        ]
        #expect(ContinuePrompt.folder(for: "t_1", in: sessions)?.path == "/new")
        #expect(ContinuePrompt.folder(for: "t_9", in: sessions) == nil)
    }

    @Test func nothingStartsUntilTheClick() {
        let starter = FakeStarter()
        let model = ContinueInNewSessionModel(starter: starter)
        #expect(model.phase == .idle)
        #expect(starter.calls.isEmpty)
    }

    @Test func aClickStartsOneSessionInTheOldFolder() async {
        let starter = FakeStarter()
        let model = ContinueInNewSessionModel(starter: starter)
        await model.start(item: makeCase(), answer: "Compact: Compact list") { [self.session("s", cwd: "/work", at: "2026-10-27T08:00:00Z")] }
        #expect(starter.calls.count == 1)
        #expect(starter.calls[0].folder.path == "/work")
        #expect(starter.calls[0].prompt.contains("Compact list"))
        #expect(model.phase == .started)
    }

    @Test func aLaunchThatFailsShowsAPlainMessage() async {
        let starter = FakeStarter()
        starter.succeeds = false
        let model = ContinueInNewSessionModel(starter: starter)
        await model.start(item: makeCase(), answer: nil) { [self.session("s", cwd: "/work", at: "2026-10-27T08:00:00Z")] }
        guard case .failed(let message) = model.phase else { Issue.record("expected failed"); return }
        #expect(message.hasPrefix(ContinueInNewSessionCopy.failedPrefix))
    }

    @Test func noKnownFolderStartsNothing() async {
        let starter = FakeStarter()
        let model = ContinueInNewSessionModel(starter: starter)
        await model.start(item: makeCase(), answer: nil) { [] }
        #expect(starter.calls.isEmpty)
        #expect(model.phase == .failed(ContinueInNewSessionCopy.noFolder))
    }

    @Test func copyHasNoEmDash() {
        for text in [ContinueInNewSessionCopy.label, ContinueInNewSessionCopy.starting, ContinueInNewSessionCopy.started,
                     ContinueInNewSessionCopy.noFolder, ContinueInNewSessionCopy.failedPrefix] {
            #expect(!text.contains("—"))
        }
    }

    // WAG-410 pass 2: a handed over reply is not a failure.
    @Test func handedOverStateDecodesFromTheWire() throws {
        let state = try JSONDecoder().decode(ReplyStatus.self, from: Data("\"handed_over\"".utf8))
        #expect(state == .handedOver)
    }

    @Test func handedOverCaseShowsAHandedOverLineAndNoFailure() {
        var item = makeCase(replyText: "Compact: Compact list")
        item = Case(
            id: item.id, taskId: item.taskId, kind: .question, title: item.title, need: item.need, why: item.why,
            recommendation: "a", recommendationWhy: "Because", options: item.options, status: .waitingOnAgent,
            hasArtifact: false, latestReplyId: "r_1", latestReplyState: .handedOver, sessionState: .ended,
            createdAt: item.createdAt, updatedAt: item.updatedAt, latestReplyAnswerText: "Compact: Compact list")
        let line = ReplyApplyCopy.line(for: item)
        #expect(line?.text == ReplyApplyCopy.handedOver)
        #expect(line?.tone == .quiet)
        #expect(!ReplyApplyCopy.handedOver.contains("\u{2014}"))
        #expect(item.replyLockState != .failed)
        #expect(!item.showsSessionClosedMark)
        #expect(AgentStatus.forCase(item) != .needsYou)
    }
}
