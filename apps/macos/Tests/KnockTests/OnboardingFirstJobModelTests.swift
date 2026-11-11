import AppKit
import Foundation
import Testing
@testable import Knock

private final class RecordingLauncher: TerminalLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [String] = []
    var launched: [String] { lock.lock(); defer { lock.unlock() }; return scripts }
    func launch(script: String) throws { lock.lock(); scripts.append(script); lock.unlock() }
}

private final class MemoryTargetStore: LaunchTargetStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: LaunchTarget?
    func load() -> LaunchTarget? { lock.lock(); defer { lock.unlock() }; return stored }
    func save(_ target: LaunchTarget) { lock.lock(); stored = target; lock.unlock() }
}

/// WAG-338 step 2: the choice of project and job, the send path to an open session, the launcher call and
/// Copy prompt. Every effect is a fake: no session gets a prompt, no Terminal opens.
@MainActor
struct OnboardingFirstJobModelTests {
    private let acme = FirstRun.session("open", project: "acme-support", started: "2026-10-09T10:12:00.000Z")

    private func ready(
        sessions: [SessionInfo]? = nil, cases: [Case] = [], fakes: OnboardingFakes = OnboardingFakes(),
        gettingStarted: GettingStartedModel? = nil
    ) async -> (model: OnboardingModel, fakes: OnboardingFakes) {
        fakes.sessions = sessions ?? [acme]
        fakes.cases = cases
        let model = makeOnboardingModel(fakes: fakes, gettingStarted: gettingStarted)
        await model.loadFirstJobData()
        return (model, fakes)
    }

    @Test func theNewestProjectIsPickedAndTheDefaultJobIsFindARealDecision() async {
        let (model, _) = await ready()
        #expect(model.selectedProject?.name == "Acme support")
        #expect(model.jobSelection == .findDecision)
        #expect(model.routing.usesOpenSession)
        #expect(model.canStart)
        #expect(model.firstJobPrompt?.contains("one real open decision") == true)
    }

    @Test func suggestionsShowWithHistoryAndAreEmptyWithout() async {
        let withHistory = await ready(cases: [FirstRun.ask("c", title: "Export: sync or async?", at: "2026-10-02T10:00:00.000Z")])
        #expect(withHistory.model.suggestions.map(\.title) == ["Export: sync or async?"])
        let without = await ready()
        #expect(without.model.suggestions.isEmpty)
    }

    @Test func pickingASuggestionChangesThePrompt() async {
        let (model, _) = await ready(cases: [FirstRun.ask("c", title: "Export: sync or async?", at: "2026-10-02T10:00:00.000Z")])
        model.selectJob(.suggestion(0))
        #expect(model.firstJobPrompt?.contains("Export: sync or async?") == true)
    }

    @Test func typeYourOwnNeedsTextBeforeItCanStart() async {
        let (model, _) = await ready()
        model.selectJob(.own)
        #expect(!model.canStart)
        #expect(model.firstJobPrompt == nil)
        model.ownJobText = "  Which queue library?  "
        #expect(model.canStart)
        #expect(model.firstJobPrompt?.contains("Which queue library?") == true)
    }

    @Test func startSendsTheJobToTheOpenSessionAndNothingElse() async {
        let (model, fakes) = await ready()
        await model.startFirstJob()
        #expect(fakes.prompts.count == 1)
        #expect(fakes.prompts[0].sessionId == "open")
        #expect(fakes.prompts[0].text == model.firstJobPrompt)
        #expect(fakes.terminalStarts.isEmpty)
        #expect(fakes.firstJobStarted == 1)
        #expect(fakes.onboardedCalls == 1)
        #expect(model.gettingStarted.isDone(.job))
        #expect(model.gettingStarted.agentOnIt?.projectName == "Acme support")
        #expect(model.gettingStarted.agentOnIt?.agent == "Claude Code")
    }

    @Test func aRefusedSendLeavesAPlainLineAndChangesNothing() async {
        let fakes = OnboardingFakes()
        fakes.promptResult = SendPromptResult(sent: false, reason: .notSupported)
        let (model, _) = await ready(fakes: fakes)
        await model.startFirstJob()
        #expect(model.startPhase == .failed(SendHelpers.failureText(.notSupported)))
        #expect(fakes.firstJobStarted == 0)
        #expect(!model.gettingStarted.isDone(.job))
        #expect(model.gettingStarted.agentOnIt == nil)
    }

    @Test func withNoOpenSessionStartOpensClaudeCodeInTheProjectFolder() async {
        let ended = FirstRun.session("old", project: "acme-support", state: .ended)
        let (model, fakes) = await ready(sessions: [ended])
        #expect(model.routing.current == .terminal)
        await model.startFirstJob()
        #expect(fakes.prompts.isEmpty, "never sends to a session when none is open")
        #expect(fakes.terminalStarts.count == 1)
        #expect(fakes.terminalStarts[0].folder.path == "/Users/me/acme-support")
        #expect(fakes.terminalStarts[0].prompt == model.firstJobPrompt)
        #expect(fakes.terminalStarts[0].topic == "Find a real decision")
        #expect(fakes.firstJobStarted == 1)
    }

    @Test func aFailedTerminalStartKeepsTheWindowAndSaysWhy() async {
        let fakes = OnboardingFakes()
        fakes.terminalFailure = "Waggle could not find Claude Code on this Mac. Copy the prompt and paste it where you work."
        let (model, _) = await ready(sessions: [FirstRun.session("old", project: "acme-support", state: .ended)], fakes: fakes)
        await model.startFirstJob()
        #expect(model.startPhase == .failed(fakes.terminalFailure!))
        #expect(fakes.firstJobStarted == 0)
    }

    @Test func changeMovesTheJobFromTheSessionToTerminal() async {
        let (model, fakes) = await ready()
        model.changeRoute()
        #expect(model.routing.current == .terminal)
        await model.startFirstJob()
        #expect(fakes.prompts.isEmpty)
        #expect(fakes.terminalStarts.count == 1)
    }

    @Test func copyPromptPutsTheTextOnTheClipboardAndCountsTheJobWithoutClosingTheWindow() async {
        let (model, fakes) = await ready()
        model.copyPrompt()
        #expect(fakes.copied == [model.firstJobPrompt ?? ""])
        #expect(model.startPhase == .copied)
        #expect(fakes.firstJobStarted == 0)
        #expect(fakes.prompts.isEmpty && fakes.terminalStarts.isEmpty)
        #expect(model.gettingStarted.isDone(.job))
        #expect(model.gettingStarted.agentOnIt?.agent == "Your agent")
    }

    @Test func somethingElseOpensTheFolderPickerAndAKeptPickSurvivesACancel() async {
        let fakes = OnboardingFakes()
        let (model, _) = await ready(fakes: fakes)
        let other = model.projects.first { $0.isSomethingElse }!
        // A cancelled picker keeps the old pick.
        fakes.pickedFolder = nil
        model.select(other)
        #expect(model.selectedProject?.name == "Acme support")
        // A picked folder becomes the project, shown by name.
        fakes.pickedFolder = URL(fileURLWithPath: "/Users/me/side-project")
        model.select(other)
        #expect(model.selectedProject?.name == "Side project")
        #expect(model.selectedProject?.folder == "/Users/me/side-project")
        #expect(model.routing.current == .terminal)
        #expect(model.projects.last?.name == "Side project")
    }

    @Test func noProjectsMeansNothingToStartUntilAFolderIsPicked() async {
        let (model, _) = await ready(sessions: [])
        #expect(model.selectedProject == nil)
        #expect(!model.canStart)
    }

    @Test func theTerminalStarterCallsTheLauncherWithClaudeAndTheFolder() async throws {
        // The real starter, with a launcher that writes to a recorder and a temp PATH: no Terminal opens.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("waggle-fj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let claude = dir.appendingPathComponent("claude")
        try "#!/bin/sh\n".write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        let recorder = RecordingLauncher()
        let store = MemoryTargetStore()
        store.save(.codexTerminal)
        let start = OnboardingModel.defaultTerminalStarter(makeLauncher: {
            SessionLauncher(
                launcher: recorder, resolvePath: { LoginShellPathResolution(path: dir.path, shellSucceeded: true) },
                pasteboard: NSPasteboard(name: NSPasteboard.Name("waggle-test-\(UUID().uuidString)")),
                launchTargetStore: store)
        })
        let failure = await start("Look at this project.", URL(fileURLWithPath: "/Users/me/acme-support"), "Find a real decision")
        #expect(failure == nil)
        #expect(recorder.launched.count == 1)
        #expect(recorder.launched[0].contains(claude.path), "starts Claude Code, not Codex, whatever the saved default is")
        #expect(recorder.launched[0].contains("/Users/me/acme-support"))
        #expect(recorder.launched[0].contains("Look at this project."))
        #expect(store.load() == .codexTerminal, "the saved launch default is not changed")
    }

    @Test func theTerminalStarterReportsAMissingClaudeInPlainWords() async {
        let recorder = RecordingLauncher()
        let start = OnboardingModel.defaultTerminalStarter(makeLauncher: {
            SessionLauncher(
                launcher: recorder, resolvePath: { LoginShellPathResolution(path: "/nonexistent-dir", shellSucceeded: true) },
                pasteboard: NSPasteboard(name: NSPasteboard.Name("waggle-test-\(UUID().uuidString)")),
                launchTargetStore: MemoryTargetStore())
        })
        let failure = await start("x", URL(fileURLWithPath: "/tmp"), "t")
        #expect(failure?.contains("could not find Claude Code") == true)
        #expect(recorder.launched.isEmpty)
    }
}
