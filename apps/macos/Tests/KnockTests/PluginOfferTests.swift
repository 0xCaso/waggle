import Testing
import Foundation
@testable import Knock

/// HAIL-136: the one-time plugin offer and the Settings On/Off control.
@MainActor
struct PluginOfferTests {
    private let mcpMode = [
        "ok    claude found",
        "ok    Claude Code MCP server registered",
        "ok    Claude Code installed as MCP entry",
        "ok    Claude Code can install the Waggle plugin",
    ]
    private let pluginMode = [
        "ok    claude found",
        "ok    Claude Code MCP server registered",
        "ok    Claude Code installed as plugin",
        "ok    Claude Code can install the Waggle plugin",
    ]

    private func status(_ lines: [String]) -> ClaudePluginStatus {
        ClaudePluginStatus(checks: lines.compactMap(DoctorLineParser.parse))
    }

    private func freshDefaults() -> UserDefaults {
        let name = "knock-plugin-offer-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: Visibility rules

    @Test func mcpModeWithPluginSupportShowsTheOffer() {
        let s = status(mcpMode)
        #expect(s.showsHomeCard(dismissed: false))
        #expect(s.showsSettingsOffer)
        #expect(s.showsToggle)
        #expect(!s.isPluginOn)
    }

    @Test func pluginModeHidesTheOfferButKeepsTheToggleOn() {
        let s = status(pluginMode)
        #expect(!s.showsHomeCard(dismissed: false))
        #expect(!s.showsSettingsOffer)
        #expect(s.showsToggle)
        #expect(s.isPluginOn)
    }

    @Test func notNowHidesTheHomeCardButTheSettingsRowStays() {
        let s = status(mcpMode)
        #expect(!s.showsHomeCard(dismissed: true))
        #expect(s.showsSettingsOffer)
    }

    @Test func noPluginSupportOrNoBundleHidesEverything() {
        let s = status(Array(mcpMode.dropLast()))
        #expect(!s.showsHomeCard(dismissed: false))
        #expect(!s.showsSettingsOffer)
        #expect(!s.showsToggle)
    }

    @Test func aClaudeCodeThatIsNotConnectedShowsNothing() {
        let s = status(["ok    claude found", "fail  Claude Code MCP server registered  (fix: knock install claude)"])
        #expect(!s.showsHomeCard(dismissed: false))
        #expect(!s.showsToggle)
    }

    @Test func theDismissalIsPersisted() {
        let defaults = freshDefaults()
        let model = PluginOfferModel(runner: FakeCommandRunner(), defaults: defaults)
        #expect(!model.dismissed)
        model.dismiss()
        #expect(model.dismissed)
        #expect(PluginOfferModel(runner: FakeCommandRunner(), defaults: defaults).dismissed)
    }

    // MARK: Commands

    @Test func commandMapping() {
        #expect(PluginCommand.arguments(turningOn: true) == ["install", "claude"])
        #expect(PluginCommand.arguments(turningOn: false) == ["install", "claude", "--mcp"])
    }

    @Test func installRunsPluginModeThenRefreshesAndTheOfferGoes() async {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: mcpMode)
        await runner.script(["doctor"], lines: pluginMode)
        let model = PluginOfferModel(runner: runner, defaults: freshDefaults())
        await model.refresh()
        #expect(model.showsHomeCard)

        await model.setPlugin(on: true)

        #expect(await runner.invocations == [["doctor"], ["install", "claude"], ["doctor"]])
        #expect(!model.showsHomeCard)
        #expect(model.status.isPluginOn)
        if case .done = model.phase {} else { Issue.record("expected done, got \(model.phase)") }
    }

    @Test func turningOffRunsTheMcpOnlyCommand() async {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: pluginMode)
        await runner.script(["doctor"], lines: mcpMode)
        let model = PluginOfferModel(runner: runner, defaults: freshDefaults())
        await model.refresh()

        await model.setPlugin(on: false)

        #expect(await runner.invocations == [["doctor"], ["install", "claude", "--mcp"], ["doctor"]])
        #expect(!model.status.isPluginOn)
        if case .done = model.phase {} else { Issue.record("expected done, got \(model.phase)") }
    }

    @Test func aFailedInstallShowsAnErrorAndKeepsTheOffer() async {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: mcpMode)
        await runner.script(["doctor"], lines: mcpMode)
        // The daemon falls back to the MCP entry and exits 0: the mode check still catches it.
        let model = PluginOfferModel(runner: runner, defaults: freshDefaults())
        await model.refresh()

        await model.setPlugin(on: true)

        if case .failed = model.phase {} else { Issue.record("expected failed, got \(model.phase)") }
        #expect(model.showsHomeCard)
    }

    @Test func aNonZeroExitIsAnError() async {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: pluginMode)
        await runner.script(["install", "claude", "--mcp"], code: 1)
        await runner.script(["doctor"], lines: mcpMode)
        let model = PluginOfferModel(runner: runner, defaults: freshDefaults())
        await model.refresh()

        await model.setPlugin(on: false)

        if case .failed = model.phase {} else { Issue.record("expected failed, got \(model.phase)") }
    }

    @Test func theAgentsRowFollowsAToggleWithoutAnotherDoctorRun() async {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: pluginMode)
        let offer = PluginOfferModel(runner: runner, defaults: freshDefaults())
        let agents = AgentsSettingsModel(runner: runner, pluginOffer: offer)
        await agents.start()
        #expect(agents.rows.first { $0.runtime == .claude }?.plugin == .plugin)

        agents.applyPluginChecks(mcpMode.compactMap(DoctorLineParser.parse))

        #expect(agents.rows.first { $0.runtime == .claude }?.plugin == OnboardingModel.PluginState.none)
        #expect(await runner.invocations == [["doctor"]])
    }

    @Test func launchRefreshStillOnlyUpdates() {
        // HAIL-136: the launch refresh never installs for a user who chose Off or has not accepted.
        #expect(PluginRefresh.arguments == ["install", "claude", "--refresh"])
    }
}
