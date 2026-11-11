import AppKit
import SwiftUI
import Testing

@testable import Knock

/// The cleaned-up Agents page: one list, one action per row, one card for asking, and a fit in a 600 pt window.
@MainActor
struct AgentsPageTests {
    private func row(_ runtime: Runtime, _ status: OnboardingModel.RuntimeRow.Status, plugin: OnboardingModel.PluginState = .none)
        -> OnboardingModel.RuntimeRow
    {
        OnboardingModel.RuntimeRow(runtime: runtime, status: status, plugin: plugin)
    }

    @Test func claudeCodeHasOneControlInEveryState() {
        let none = AgentRowAction.forRow(row(.claude, .notConnected))
        #expect(none == .connect)
        #expect(AgentRowAction.forRow(row(.claude, .connected, plugin: .plugin)) == nil)
        #expect(AgentRowAction.forRow(row(.claude, .connected, plugin: .pluginWithOldEntry)) == .removeOldEntry)
        #expect(AgentRowAction.forRow(row(.claude, .connected), pluginOfferApplies: true) == .installPlugin)
        #expect(AgentRowAction.forRow(row(.claude, .connected)) == .reconnect)
        #expect(AgentRowAction.forRow(row(.claude, .couldNotCheck)) == .retry)
        #expect(AgentRowAction.forRow(row(.claude, .connecting)) == nil)
    }

    @Test func codexOffersADownloadOnlyWhenItIsMissing() {
        #expect(AgentRowAction.forRow(row(.codex, .notInstalled), downloadWhenMissing: true) == .download)
        #expect(AgentRowAction.forRow(row(.codex, .notInstalled)) == nil)
        #expect(AgentRowAction.forRow(row(.codex, .notConnected), downloadWhenMissing: true) == .connect)
    }

    @Test func theRowCopyIsPlain() {
        let texts = [
            AgentPlaceCopy.claudeApp, AgentPlaceCopy.claudeAppConnected, AgentPlaceCopy.codexPlugin,
            AgentPlaceCopy.superset, AgentPlaceCopy.conductor, SettingsPage.agents.subtitle,
            AgentQuestionsCopy.catchBody, AgentQuestionsCopy.ruleBody,
        ]
        #expect(texts.allSatisfy { !$0.contains("\u{2014}") })
    }

    @Test func theAgentsPageIsOneLineOfHeader() {
        #expect(SettingsPage.agents.subtitle.count < 70)
    }

    /// One agent connected, the rest not: the header, the list and the asking card fit 600 pt high.
    @Test func thePageFitsA600PointWindowWithOneAgentConnected() async throws {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: [
            "ok    claude found",
            "ok    Claude Code MCP server registered",
            "ok    Claude Code installed as plugin",
            "skip  codex found  (fix: install Codex)",
        ])
        let agents = AgentsSettingsModel(runner: runner)
        await agents.start()
        #expect(agents.rows.first { $0.runtime == .claude }?.status == .connected)

        let ruleRunner = FakeCommandRunner()
        let report = """
        {"lines":["Ask the human through Waggle (waggle_ask), not in the terminal, for the requests set in Waggle > Settings > Requests.","Call waggle_settings if you do not know them.","Give options and a recommendation, then wait for the reply."],"agents":{"claude":{"path":"\(NSHomeDirectory())/.claude/CLAUDE.md","present":true,"state":"missing"},"codex":{"path":"\(NSHomeDirectory())/.codex/AGENTS.md","present":true,"state":"missing"}}}
        """
        await ruleRunner.script(AgentRuleCommand.status, lines: [report])
        let rule = AgentRuleModel(runner: ruleRunner)
        await rule.refresh()
        #expect(rule.report?.lines.count == 3)

        let socketPath = makeTempSocketPath()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        let config = ClaudeDesktopConfig(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("agents_page_\(UUID().uuidString)/claude_desktop_config.json"))
        let content = AgentsPageContent(
            client: client, agentsModel: agents, claudeApp: ClaudeAppModel(config: config, binaryPath: { nil }),
            t3: T3ConnectionModel(), ruleModel: rule)
        let width: CGFloat = 554
        let body = NSHostingView(rootView: VStack(alignment: .leading, spacing: 18) { content }.frame(width: width))
        let header = NSHostingView(rootView: VStack(alignment: .leading, spacing: 4) {
            Text(SettingsPage.agents.title).knockTextStyle(Theme.Typography.dialogTitle19w650)
            Text(SettingsPage.agents.subtitle).knockTextStyle(Theme.Typography.body12_5w400)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(width: width, alignment: .leading))
        // The chrome pads 24 above and below and puts 18 between the header and the content.
        let total = body.fittingSize.height + header.fittingSize.height + 18 + 48
        #expect(total <= 600, "page is \(total) pt high: body \(body.fittingSize.height), header \(header.fittingSize.height)")
    }
}
