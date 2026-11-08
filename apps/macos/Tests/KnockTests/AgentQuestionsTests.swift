import Foundation
import Testing

@testable import Knock

/// WAG-265: the optional Waggle rule and the "Catch questions in the terminal" switch. A fake runner
/// stands in for `waggle`: no file is written.
@MainActor
struct AgentQuestionsTests {
    private func report(claude: String, codex: String, claudePresent: Bool = true, codexPresent: Bool = true) -> String {
        """
        {"lines":["Ask the human through Waggle (waggle_ask), not in the terminal, for the requests set in Waggle > Settings > Requests.","Call waggle_settings if you do not know them.","Give options and a recommendation, then wait for the reply."],"agents":{"claude":{"path":"/h/.claude/CLAUDE.md","present":\(claudePresent),"state":"\(claude)"},"codex":{"path":"/h/.codex/AGENTS.md","present":\(codexPresent),"state":"\(codex)"}}}
        """
    }

    @Test func statusShowsTheThreeLinesAndNeverWrites() async {
        let runner = FakeCommandRunner()
        await runner.script(AgentRuleCommand.status, lines: [report(claude: "missing", codex: "missing")])
        let model = AgentRuleModel(runner: runner)
        await model.refresh()
        #expect(model.report?.lines.count == 3)
        #expect(!model.isAdded)
        #expect(model.hasCodex)
        #expect(await runner.invocations == [AgentRuleCommand.status])
    }

    @Test func addWritesOnlyForTheAgentsSetUpAndThenShowsRemove() async {
        let runner = FakeCommandRunner()
        await runner.script(AgentRuleCommand.status, lines: [report(claude: "missing", codex: "missing", codexPresent: false)])
        await runner.script(["rule", "add", "claude"], lines: [report(claude: "added", codex: "missing", codexPresent: false)])
        await runner.script(AgentRuleCommand.status, lines: [report(claude: "added", codex: "missing", codexPresent: false)])
        let model = AgentRuleModel(runner: runner)
        await model.refresh()
        #expect(!model.hasCodex)
        await model.set(added: true)
        #expect(model.isAdded)
        #expect(model.phase == .idle)
        #expect(await runner.invocations.contains(["rule", "add", "claude"]))
    }

    @Test func removeRunsForThePresentAgents() async {
        let runner = FakeCommandRunner()
        await runner.script(AgentRuleCommand.status, lines: [report(claude: "added", codex: "added")])
        await runner.script(["rule", "remove", "claude", "codex"], lines: [report(claude: "missing", codex: "missing")])
        await runner.script(AgentRuleCommand.status, lines: [report(claude: "missing", codex: "missing")])
        let model = AgentRuleModel(runner: runner)
        await model.refresh()
        #expect(model.isAdded)
        await model.set(added: false)
        #expect(!model.isAdded)
    }

    @Test func aFailedWriteShowsAPlainMessage() async {
        let runner = FakeCommandRunner()
        await runner.script(AgentRuleCommand.status, lines: [report(claude: "missing", codex: "missing")])
        await runner.script(["rule", "add", "claude", "codex"], code: 1)
        let model = AgentRuleModel(runner: runner)
        await model.refresh()
        await model.set(added: true)
        #expect(model.phase == .failed(AgentQuestionsCopy.addFailed))
        #expect(!AgentQuestionsCopy.addFailed.contains("—"))
    }

    @Test func aBrokenFileIsReported() async {
        let runner = FakeCommandRunner()
        await runner.script(AgentRuleCommand.status, lines: [report(claude: "damaged", codex: "missing", codexPresent: false)])
        let model = AgentRuleModel(runner: runner)
        await model.refresh()
        #expect(model.hasDamagedFile)
        #expect(!model.isAdded)
    }

    @Test func codexNoteIsOnePlainLine() {
        #expect(AgentQuestionsCopy.codexNote == "Codex has no stop check, so this rule is how it learns to bring decisions to Waggle.")
    }

    @Test func catchQuestionsDefaultsOnAndSavesTheChoice() async {
        var saved: [Bool] = []
        let model = CatchQuestionsModel(load: { throw URLError(.cannotConnectToHost) }, save: { saved.append($0); return $0 })
        await model.refresh()
        #expect(model.isOn)
        await model.set(false)
        #expect(!model.isOn)
        #expect(saved == [false])
    }

    @Test func catchQuestionsGoesBackWhenTheSaveFails() async {
        let model = CatchQuestionsModel(load: { true }, save: { _ in throw URLError(.cannotConnectToHost) })
        await model.refresh()
        await model.set(false)
        #expect(model.isOn)
    }
}
