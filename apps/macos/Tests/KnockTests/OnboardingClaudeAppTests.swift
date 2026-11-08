import Testing
import Foundation
@testable import Knock

/// A Claude app model on a temp config file, never the real Claude desktop config.
@MainActor
func makeTempClaudeAppModel() -> (model: ClaudeAppModel, root: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("knock-onb-claude-\(UUID().uuidString)")
    let dir = root.appendingPathComponent("Claude")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let config = ClaudeDesktopConfig(fileURL: dir.appendingPathComponent("claude_desktop_config.json"))
    let binary = root.appendingPathComponent("knock")
    try? Data().write(to: binary)
    return (ClaudeAppModel(config: config, binaryPath: { binary.path }), root)
}

/// HAIL-175: onboarding with the Claude app.
@MainActor
struct OnboardingClaudeAppTests {
    private enum TestError: Error { case timedOut }

    private func waitUntil(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        if try await !pollUntil(timeout, condition) { throw TestError.timedOut }
    }

    private func nothingConnected() async -> FakeCommandRunner {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: [
            "ok    claude found", "fail  Claude Code MCP server registered  (fix: waggle install claude)",
        ])
        return runner
    }

    @Test func connectSucceedsWithOnlyTheClaudeApp() async throws {
        let (app, root) = makeTempClaudeAppModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeOnboardingModel(runner: await nothingConnected(), claudeApp: app)
        model.start()
        try await waitUntil { if case .loaded = model.connectPhase { return true } else { return false } }
        #expect(!model.connectSucceeded)
        model.claudeApp.confirmAdd()
        #expect(model.connectSucceeded)
        #expect(model.connectedAgentName == "The Claude app")
        model.continueFromConnect()
        #expect(model.screen == .firstJob)
    }
}
