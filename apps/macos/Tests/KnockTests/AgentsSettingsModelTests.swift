import Testing
import Foundation
@testable import Knock

/// HAIL-50: the Settings window's Agents page runs the same `knock doctor`
/// probe onboarding's O1 does, reusing `DoctorLineParser` and
/// `OnboardingModel.status(for:in:)` for the doctor-line to row status
/// mapping (contract test: "doctor-line to row status mapping (reuse
/// existing parser)"). `FakeCommandRunner` is declared in OnboardingTests.swift
/// and shared across the test target, like `OnboardingModelTests` already
/// reuses it.
@MainActor
struct AgentsSettingsModelTests {
    private func waitUntil(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        if try await !pollUntil(timeout, condition) { Issue.record("timed out waiting") }
    }

    @Test func startProbesDoctorAndMapsEveryRuntimeStatus() async throws {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: [
            "ok    service reachable, or startable on demand",
            "ok    claude found",
            "ok    Claude Code MCP server registered",
            "skip  codex found  (fix: install Codex)",
        ])
        let model = AgentsSettingsModel(runner: runner)

        await model.start()

        #expect(model.rows.first { $0.runtime == .claude }?.status == .connected)
        #expect(model.rows.first { $0.runtime == .codex }?.status == .notInstalled)
        let invocations = await runner.invocations
        #expect(invocations == [["doctor"]])
    }

    @Test func aRuntimeFoundButNotRegisteredIsNotConnected() async throws {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: [
            "ok    claude found",
            "fail  Claude Code MCP server registered  (fix: knock install claude)",
        ])
        let model = AgentsSettingsModel(runner: runner)

        await model.start()

        #expect(model.rows.first { $0.runtime == .claude }?.status == .notConnected)
    }

    @Test func connectRunsInstallThenReProbesDoctor() async throws {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: [
            "ok    claude found",
            "fail  Claude Code MCP server registered  (fix: knock install claude)",
        ])
        await runner.script(["doctor"], lines: [
            "ok    claude found",
            "ok    Claude Code MCP server registered",
        ])
        let model = AgentsSettingsModel(runner: runner)
        await model.start()
        #expect(model.rows.first { $0.runtime == .claude }?.status == .notConnected)

        model.connect(.claude)
        try await waitUntil { model.rows.first { $0.runtime == .claude }?.status == .connected }

        let invocations = await runner.invocations
        #expect(invocations == [["doctor"], ["install", "claude"], ["doctor"]])
    }

    // MARK: - HAIL-134: the Knock Claude Code plugin

    @Test func pluginOnlyMarksTheClaudeRowAsInstalledAsPlugin() async throws {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: [
            "ok    claude found",
            "ok    Claude Code MCP server registered",
            "ok    Claude Code installed as plugin",
            "skip  codex found  (fix: install Codex)",
        ])
        let model = AgentsSettingsModel(runner: runner)

        await model.start()

        let claude = model.rows.first { $0.runtime == .claude }
        #expect(claude?.status == .connected)
        #expect(claude?.plugin == .plugin)
        #expect(model.rows.first { $0.runtime == .codex }?.plugin == PluginStateNone)
    }

    @Test func withoutThePluginTheRowHasNoPluginLabel() async throws {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: [
            "ok    claude found",
            "ok    Claude Code MCP server registered",
        ])
        let model = AgentsSettingsModel(runner: runner)

        await model.start()

        #expect(model.rows.first { $0.runtime == .claude }?.plugin == PluginStateNone)
    }

    @Test func bothTheEntryAndThePluginOfferToRemoveTheOldEntryAndInstallFixesIt() async throws {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: [
            "ok    claude found",
            "ok    Claude Code MCP server registered",
            "ok    Claude Code installed as plugin",
            "fail  Claude Code runs Waggle twice (the plugin and an older MCP entry)  (fix: knock install claude)",
        ])
        await runner.script(["doctor"], lines: [
            "ok    claude found",
            "ok    Claude Code MCP server registered",
            "ok    Claude Code installed as plugin",
        ])
        let model = AgentsSettingsModel(runner: runner)
        await model.start()
        #expect(model.rows.first { $0.runtime == .claude }?.plugin == .pluginWithOldEntry)

        model.removeOldEntry(.claude)
        try await waitUntil { model.rows.first { $0.runtime == .claude }?.plugin == .plugin }

        let invocations = await runner.invocations
        #expect(invocations == [["doctor"], ["install", "claude"], ["doctor"]])
    }
}

private let PluginStateNone = OnboardingModel.PluginState.none
