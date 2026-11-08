import Testing
import Foundation
@testable import Knock

/// Scripts one canned response per call, so a test never launches a real
/// shell (Amendments: "Add a unit test that uses an injected shell runner").
struct FakeLoginShellPathRunner: LoginShellPathRunning {
    let response: String?

    func run(shell: String, command: String, timeoutSeconds: TimeInterval) async -> String? {
        response
    }
}

struct LoginShellPathTests {
    @Test func appendsMissingFallbackDirectoriesAfterTheShellsOwnPath() async {
        let runner = FakeLoginShellPathRunner(response: "/usr/bin:/bin")
        let resolution = await LoginShellPath.resolve(environment: [:], runner: runner, extraDirectories: [])

        let expected = (["/usr/bin", "/bin"] + LoginShellPath.fallbackDirectories).joined(separator: ":")
        #expect(resolution.path == expected)
        #expect(resolution.shellSucceeded)
    }

    @Test func doesNotDuplicateAFallbackDirectoryTheShellAlreadyHas() async {
        let runner = FakeLoginShellPathRunner(response: "/usr/bin:\(NSHomeDirectory())/.local/bin")
        let resolution = await LoginShellPath.resolve(environment: [:], runner: runner, extraDirectories: [])

        #expect(resolution.path.components(separatedBy: ":").filter { $0 == "\(NSHomeDirectory())/.local/bin" }.count == 1)
    }

    @Test func fallsBackToTheEnvironmentPathWhenTheShellCannotBeAsked() async {
        let runner = FakeLoginShellPathRunner(response: nil)
        let resolution = await LoginShellPath.resolve(environment: ["PATH": "/usr/bin:/bin"], runner: runner, extraDirectories: [])

        let expected = (["/usr/bin", "/bin"] + LoginShellPath.fallbackDirectories).joined(separator: ":")
        #expect(resolution.path == expected)
        #expect(!resolution.shellSucceeded)
    }

    @Test func readsThePathBetweenMarkersAndIgnoresRcFileNoise() async {
        let marker = LoginShellPath.pathMarker
        let runner = FakeLoginShellPathRunner(response: "welcome\n\(marker)/usr/bin:/nvm/bin\(marker)\n")
        let resolution = await LoginShellPath.resolve(environment: [:], runner: runner, extraDirectories: [])
        #expect(resolution.path.hasPrefix("/usr/bin:/nvm/bin:"))
        #expect(resolution.shellSucceeded)
    }

    @Test func addsNvmDirectoriesNewestFirstWhenTheShellMissesThem() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("waggle-nvm-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: home) }
        for v in ["v9.1.0", "v24.15.0"] {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(".nvm/versions/node/\(v)/bin"), withIntermediateDirectories: true)
        }
        let nvm = LoginShellPath.nvmDirectories(home: home.path)
        #expect(nvm.map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent } == ["v24.15.0", "v9.1.0"])
        let runner = FakeLoginShellPathRunner(response: nil)
        let resolution = await LoginShellPath.resolve(
            environment: ["PATH": "/usr/bin:/bin"], runner: runner, extraDirectories: nvm)
        #expect(resolution.path.contains(nvm[0]))
    }
}

struct ProcessCommandRunnerFixTextTests {
    /// HAIL-218: every app-run waggle command, the launch refresh included, gets the login-shell PATH.
    @Test func childEnvironmentCarriesTheLoginShellPath() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("waggle-env-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("waggle")
        try "#!/bin/sh\necho \"$PATH\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let runner = ProcessCommandRunner(
            environment: ["PATH": "/usr/bin:/bin"], bundledBinaryURL: script,
            loginShellPathRunner: FakeLoginShellPathRunner(response: "/usr/bin:/nvm/node/bin"))
        final class Box: @unchecked Sendable { var lines: [String] = [] }
        let box = Box()
        let code = await runner.run(["install", "codex", "--refresh"], onLine: { box.lines.append($0) })
        #expect(code == 0)
        #expect(box.lines.first?.contains("/nvm/node/bin") == true)
    }

    @Test func rewritesClaudeFoundFixTextWhenTheShellProbeFailed() {
        // KNOCK-20: a missing runtime is "skip", not "fail".
        let line = "skip  claude found  (fix: install Claude Code)"
        let rewritten = ProcessCommandRunner.rewriteFixTextIfPathResolutionFailed(line, shellSucceeded: false)
        #expect(rewritten == "skip  claude found  (fix: Could not check)")
    }

    @Test func rewritesCodexFoundFixTextWhenTheShellProbeFailed() {
        let line = "skip  codex found  (fix: install Codex)"
        let rewritten = ProcessCommandRunner.rewriteFixTextIfPathResolutionFailed(line, shellSucceeded: false)
        #expect(rewritten == "skip  codex found  (fix: Could not check)")
    }

    @Test func leavesAGenuineClaudeFoundSkipAloneWhenTheShellProbeSucceeded() {
        let line = "skip  claude found  (fix: install Claude Code)"
        let rewritten = ProcessCommandRunner.rewriteFixTextIfPathResolutionFailed(line, shellSucceeded: true)
        #expect(rewritten == line)
    }

    @Test func leavesOtherChecksAlone() {
        let line = "fail  Claude Code MCP server registered  (fix: knock install claude)"
        let rewritten = ProcessCommandRunner.rewriteFixTextIfPathResolutionFailed(line, shellSucceeded: false)
        #expect(rewritten == line)
    }

    @Test func leavesAnOkLineAlone() {
        let line = "ok    claude found"
        let rewritten = ProcessCommandRunner.rewriteFixTextIfPathResolutionFailed(line, shellSucceeded: false)
        #expect(rewritten == line)
    }
}
