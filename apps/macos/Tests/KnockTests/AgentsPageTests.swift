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

    /// One agent connected, the rest not: the header, the list and the asking card.
    /// The target is 600 pt. With the app's fonts the page is 633 pt today, so it scrolls by 33 pt.
    /// This bound stops it from growing; lower it to 600 when the page is trimmed.
    @Test func thePageStaysNearA600PointWindowWithOneAgentConnected() async throws {
        // Measure with the app's own fonts. Without them the fallback font is narrower and the page looks shorter.
        FontRegistration.registerBundledFonts()
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
            t3: t3NotOnThisMac(), ruleModel: rule)
        let width: CGFloat = 554
        let body = NSHostingView(rootView: VStack(alignment: .leading, spacing: 18) { content }.frame(width: width))
        let header = NSHostingView(rootView: VStack(alignment: .leading, spacing: 4) {
            Text(SettingsPage.agents.title).knockTextStyle(Theme.Typography.dialogTitle19w650)
            Text(SettingsPage.agents.subtitle).knockTextStyle(Theme.Typography.body12_5w400)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(width: width, alignment: .leading))
        // The chrome pads 24 above and below and puts 18 between the header and the content.
        let total = body.fittingSize.height + header.fittingSize.height + 18 + 48
        #expect(total <= 635, "page is \(total) pt high: body \(body.fittingSize.height), header \(header.fittingSize.height)")
    }
}

// MARK: - A T3 Code model that reads nothing from the real Mac

private final class NoSecrets: SecretStoring, @unchecked Sendable {
    func load() -> String? { nil }
    func save(_ secret: String) -> Bool { false }
    func delete() {}
}

private final class NoMeta: T3MetaStoring, @unchecked Sendable {
    var expiry: Date? { nil }
    var remindedFor: Date? { nil }
    func setExpiry(_ date: Date?) {}
    func setRemindedFor(_ date: Date?) {}
}

private final class NoCLI: CLIRunning, @unchecked Sendable {
    func run(executable: String, arguments: [String], searchPath: String, timeout: TimeInterval) async -> CLIResult {
        CLIResult(exitCode: 1, stdout: "", stderr: "not in a test")
    }
}

private final class NoT3App: ExternalAppOpening, @unchecked Sendable {
    func isAppInstalled(bundleIdentifier: String) -> Bool { false }
    func appURL(toOpen url: URL) -> URL? { nil }
    func isRunning(appURL: URL) -> Bool { false }
    func launchApp(at appURL: URL) {}
    func open(url: URL) -> Bool { false }
}

/// The page's `.task` refreshes this model. With the real one, a slow run measured the page with this Mac's
/// own T3 Code state (Keychain, defaults, the t3 command), and the height changed with it.
@MainActor private func t3NotOnThisMac() -> T3ConnectionModel {
    T3ConnectionModel(
        secrets: NoSecrets(), meta: NoMeta(), runner: NoCLI(), opener: NoT3App(),
        resolvePath: { LoginShellPathResolution(path: "/nonexistent-bin", shellSucceeded: true) },
        homeDirectory: "/nonexistent-home")
}
