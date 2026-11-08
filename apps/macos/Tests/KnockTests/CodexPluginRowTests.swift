import Testing
import Foundation
@testable import Knock

/// HAIL-137: the Agents row for Codex follows `knock doctor` like Claude Code's.
@MainActor
struct CodexPluginRowTests {
    private func checks(_ lines: [String]) -> [DoctorCheckResult] {
        lines.compactMap(DoctorLineParser.parse)
    }

    @Test func codexInstalledAsPluginShowsThePluginState() {
        let c = checks([
            "ok    codex found",
            "ok    Codex MCP server registered",
            "ok    Codex installed as plugin",
        ])
        #expect(OnboardingModel.pluginState(for: .codex, in: c) == .plugin)
        #expect(OnboardingModel.pluginState(for: .claude, in: c) == .none)
    }

    @Test func codexWithThePluginAndAnOldEntryOffersToRemoveIt() {
        let c = checks([
            "ok    Codex MCP server registered",
            "ok    Codex installed as plugin",
            "fail  Codex runs Waggle twice (the plugin and an older MCP entry)  (fix: knock install codex)",
        ])
        #expect(OnboardingModel.pluginState(for: .codex, in: c) == .pluginWithOldEntry)
    }

    @Test func codexInMcpModeHasNoPluginLabel() {
        let c = checks([
            "ok    Codex MCP server registered",
            "ok    Codex installed as MCP entry",
            "ok    Codex can install the Waggle plugin",
        ])
        #expect(OnboardingModel.pluginState(for: .codex, in: c) == .none)
    }

    @Test func launchRefreshRunsForCodexToo() {
        #expect(PluginRefresh.codexArguments == ["install", "codex", "--refresh"])
    }
}
