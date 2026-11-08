import AppKit
import Foundation
import Testing
@testable import Knock

// WAG-263: Superset and Conductor launch targets. No test runs the real `superset` or opens a
// real URL: a fake CLI runner and a fake opener stand in.

private final class FakeCLIRunner: CLIRunning, @unchecked Sendable {
    struct Call: Equatable { var executable: String; var arguments: [String]; var timeout: TimeInterval }
    private let lock = NSLock()
    private var _calls: [Call] = []
    private var results: [String: CLIResult] = [:]
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }

    /// The result for a command, keyed by its first two arguments ("projects list", "ws create", "ws open").
    func stub(_ key: String, _ result: CLIResult) { lock.lock(); results[key] = result; lock.unlock() }

    func run(executable: String, arguments: [String], searchPath: String, timeout: TimeInterval) async -> CLIResult {
        return record(Call(executable: executable, arguments: arguments, timeout: timeout))
    }

    private func record(_ call: Call) -> CLIResult {
        lock.lock(); defer { lock.unlock() }
        _calls.append(call)
        return results[call.arguments.prefix(2).joined(separator: " ")] ?? CLIResult(exitCode: 1, stdout: "", stderr: "unstubbed")
    }
}

private final class FakeOpener: ExternalAppOpening, @unchecked Sendable {
    private let lock = NSLock()
    var conductorInstalled = false
    var openSucceeds = true
    private var _opened: [URL] = []
    var opened: [URL] { lock.lock(); defer { lock.unlock() }; return _opened }
    func isAppInstalled(bundleIdentifier: String) -> Bool { false }
    func appURL(toOpen url: URL) -> URL? {
        url.scheme == "conductor" && conductorInstalled ? URL(fileURLWithPath: "/Applications/Conductor.app") : nil
    }
    func isRunning(appURL: URL) -> Bool { true }
    func launchApp(at appURL: URL) {}
    func open(url: URL) -> Bool { lock.lock(); _opened.append(url); defer { lock.unlock() }; return openSucceeds }
}

private final class FakeStore: LaunchTargetStoring, @unchecked Sendable {
    private var stored: LaunchTarget?
    init(_ initial: LaunchTarget? = nil) { stored = initial }
    func load() -> LaunchTarget? { stored }
    func save(_ target: LaunchTarget) { stored = target }
}

private struct NoTerminal: TerminalLaunching { func launch(script: String) throws {} }

private func ok(_ stdout: String) -> CLIResult { CLIResult(exitCode: 0, stdout: stdout, stderr: "") }

/// A temp folder holding an executable `superset`, so `findCLI` finds it. The fake runner never runs it.
private func makeBin(withSuperset: Bool = true) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("knock-superset-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if withSuperset {
        let file = dir.appendingPathComponent("superset")
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    return dir
}

struct SupersetCommandTests {
    @Test func createArgumentsKeepThePromptAsOneArgument() {
        let prompt = "Read \"/a b/it's.md\".\nUse $HOME `x` ; rm -rf / & 'done'\n\tend"
        let args = SupersetCommand.createArguments(projectID: "p-1", name: "My PRD", branch: "my-prd-ab12", agent: "codex", prompt: prompt)
        #expect(args == [
            "ws", "create", "--local", "--project", "p-1", "--name", "My PRD", "--branch", "my-prd-ab12",
            "--agent", "codex", "--prompt", prompt, "--quiet",
        ])
        #expect(args.filter { $0 == prompt }.count == 1)
        #expect(SupersetCommand.openArguments(workspaceID: "w-9") == ["ws", "open", "w-9", "--local"])
        #expect(SupersetCommand.projectsArguments == ["projects", "list", "--local", "--json"])
    }

    @Test func agentFollowsTheTarget() {
        #expect(SupersetCommand.agentID(for: .claudeSuperset) == "claude")
        #expect(SupersetCommand.agentID(for: .codexSuperset) == "codex")
    }

    @Test func nameAndBranchAreShortAndSafe() {
        #expect(SupersetCommand.shortName(topic: "  Plan\nof \"work\" ") == "Plan of 'work'")
        #expect(SupersetCommand.shortName(topic: " ") == "Waggle session")
        #expect(SupersetCommand.shortName(topic: String(repeating: "a", count: 200)).count == 60)
        #expect(SupersetCommand.branchSlug(topic: "My PRD: v2 / Auth!", suffix: "ab12") == "my-prd-v2-auth-ab12")
        #expect(SupersetCommand.branchSlug(topic: "!!!", suffix: "ab12") == "waggle-ab12")
        #expect(SupersetCommand.branchSlug(topic: "--x--", suffix: "") == "x")
        #expect(SupersetCommand.branchSlug(topic: String(repeating: "word ", count: 30), suffix: "z").count <= 42)
    }

    private let list = """
    [{"id":"p-1","name":"waggle","path":"/Users/me/waggle"},{"id":"p-2","name":"other","repoPath":"/Users/me/other/"}]
    """

    @Test func projectMatchesByPathIncludingTrailingSlash() {
        #expect(SupersetCommand.matchProject(listJSON: list, folder: "/Users/me/waggle") == "p-1")
        #expect(SupersetCommand.matchProject(listJSON: list, folder: "/Users/me/waggle/") == "p-1")
        #expect(SupersetCommand.matchProject(listJSON: list, folder: "/Users/me/other") == "p-2")
        #expect(SupersetCommand.matchProject(listJSON: list, folder: "/Users/me/waggle/sub") == nil)
        #expect(SupersetCommand.matchProject(listJSON: list, folder: "/Users/me/wag") == nil)
        #expect(SupersetCommand.matchProject(listJSON: "not json", folder: "/x") == nil)
        #expect(SupersetCommand.matchProject(listJSON: "{\"projects\":[{\"id\":\"p-3\",\"path\":\"/x\"}]}", folder: "/x") == "p-3")
    }

    @Test func projectMatchesThroughSymlinks() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("knock-link-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real")
        let link = base.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: base) }
        let json = "[{\"id\":\"p-1\",\"path\":\"\(real.path)\"}]"
        #expect(SupersetCommand.matchProject(listJSON: json, folder: link.path) == "p-1")
        let jsonLink = "[{\"id\":\"p-1\",\"path\":\"\(link.path)/\"}]"
        #expect(SupersetCommand.matchProject(listJSON: jsonLink, folder: real.path) == "p-1")
    }

    @Test func workspaceIDComesFromQuietOrJSONOutput() {
        #expect(SupersetCommand.workspaceID(from: "w-1\n") == "w-1")
        #expect(SupersetCommand.workspaceID(from: "{\"id\":\"w-2\"}") == "w-2")
        #expect(SupersetCommand.workspaceID(from: "{\"workspace\":{\"id\":\"w-3\"}}") == "w-3")
        #expect(SupersetCommand.workspaceID(from: "") == nil)
        #expect(SupersetCommand.workspaceID(from: "Something went wrong here") == nil)
    }

    @Test func eachUnavailableReasonHasItsOwnPlainLine() async throws {
        let bin = try makeBin()
        let none = try makeBin(withSuperset: false)
        let home = try makeBin(withSuperset: false)
        defer { for d in [bin, none, home] { try? FileManager.default.removeItem(at: d) } }
        let runner = FakeCLIRunner()
        func check(_ path: URL) async -> SupersetStatus {
            await SupersetCommand.check(folder: "/Users/me/waggle", searchPath: path.path, homeDirectory: home.path, runner: runner).status
        }

        #expect(await check(none) == .blocked(.notOnMac))
        #expect(runner.calls.isEmpty)

        runner.stub("projects list", CLIResult(exitCode: 1, stdout: "", stderr: "Not logged in. Run: superset auth login"))
        #expect(await check(bin) == .blocked(.signIn))

        runner.stub("projects list", CLIResult(exitCode: 1, stdout: "", stderr: "connect ECONNREFUSED 127.0.0.1:51234"))
        #expect(await check(bin) == .blocked(.startService))

        runner.stub("projects list", CLIResult(exitCode: -1, stdout: "", stderr: "", timedOut: true))
        #expect(await check(bin) == .blocked(.startService))

        runner.stub("projects list", ok("[{\"id\":\"p-9\",\"path\":\"/elsewhere\"}]"))
        #expect(await check(bin) == .blocked(.addFolder))

        runner.stub("projects list", ok("[{\"id\":\"p-1\",\"path\":\"/Users/me/waggle\"}]"))
        #expect(await check(bin) == .ready)

        #expect(runner.calls.allSatisfy { $0.arguments == SupersetCommand.projectsArguments && $0.timeout == 2 })
        #expect(LaunchBlock.notOnMac.text == "Not on this Mac")
        #expect(LaunchBlock.signIn.text == "Sign in to Superset first")
        #expect(LaunchBlock.addFolder.text == "Add this folder in Superset first")
        #expect(LaunchBlock.startService.text == "Start Superset first")
    }

    @Test func cliIsFoundInTheSupersetAppFolderToo() throws {
        let home = try makeBin(withSuperset: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let appBin = home.appendingPathComponent(".superset/bin")
        try FileManager.default.createDirectory(at: appBin, withIntermediateDirectories: true)
        let file = appBin.appendingPathComponent("superset")
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        #expect(SupersetCommand.findCLI(searchPath: "/nonexistent-knock", homeDirectory: home.path) == file.path)
        #expect(SupersetCommand.findCLI(searchPath: "/nonexistent-knock", homeDirectory: "/nonexistent-home") == nil)
    }

    @Test func launcherCreatesThenOpensTheWorkspace() async throws {
        let bin = try makeBin()
        defer { try? FileManager.default.removeItem(at: bin) }
        let runner = FakeCLIRunner()
        runner.stub("projects list", ok("[{\"id\":\"p-1\",\"path\":\"/Users/me/waggle\"}]"))
        runner.stub("ws create", ok("w-7\n"))
        runner.stub("ws open", ok(""))
        let launcher = SupersetLauncher(runner: runner, homeDirectory: "/nonexistent-home", suffix: { "ab12" })
        let prompt = "Read /tmp/a b.md.\nUse the topic \"Auth\"."
        let result = await launcher.launch(
            target: .codexSuperset, folder: "/Users/me/waggle/", topic: "My PRD", prompt: prompt, searchPath: bin.path)
        #expect(result == .started)
        let calls = runner.calls
        #expect(calls.count == 3)
        #expect(calls[1].arguments == SupersetCommand.createArguments(
            projectID: "p-1", name: "My PRD", branch: "my-prd-ab12", agent: "codex", prompt: prompt))
        #expect(calls[2].arguments == ["ws", "open", "w-7", "--local"])
        #expect(calls.allSatisfy { $0.executable == bin.appendingPathComponent("superset").path })
    }

    @Test func launcherStopsWithAPlainMessageAtEachFailure() async throws {
        let bin = try makeBin()
        defer { try? FileManager.default.removeItem(at: bin) }
        let runner = FakeCLIRunner()
        let launcher = SupersetLauncher(runner: runner, homeDirectory: "/nonexistent-home", suffix: { "x" })
        func go() async -> SupersetLaunchResult {
            await launcher.launch(target: .claudeSuperset, folder: "/f", topic: "t", prompt: "p", searchPath: bin.path)
        }
        runner.stub("projects list", CLIResult(exitCode: 1, stdout: "", stderr: "Not logged in"))
        #expect(await go() == .failed("Sign in to Superset first. Then try again, or copy the prompt instead."))
        runner.stub("projects list", ok("[{\"id\":\"p-1\",\"path\":\"/f\"}]"))
        runner.stub("ws create", CLIResult(exitCode: 1, stdout: "", stderr: "boom"))
        #expect(await go() == .failed("Superset could not make the workspace. Copy the prompt instead."))
        runner.stub("ws create", ok("w-1"))
        runner.stub("ws open", CLIResult(exitCode: 1, stdout: "", stderr: "no app"))
        if case .failed(let text) = await go() { #expect(text.contains("could not open it")) } else { Issue.record("expected a failure") }
        #expect(!runner.calls.contains { $0.arguments.first == "agents" })
    }
}

struct ConductorURLTests {
    @Test func promptAndFolderArePercentEncodedInTheFlatForm() throws {
        let url = try #require(ConductorURL.build(prompt: "Read /tmp/a b.md & fix \"it\"\nnow = 100% é", folder: "/Users/me/my proj"))
        let text = url.absoluteString
        #expect(text.hasPrefix("conductor://prompt="))
        #expect(!text.contains(" ") && !text.contains("\n") && !text.contains("\""))
        #expect(text.components(separatedBy: "&").count == 2)
        #expect(text.hasSuffix("&path=%2FUsers%2Fme%2Fmy%20proj"))
        #expect(text.contains("prompt=Read%20%2Ftmp%2Fa%20b.md%20%26%20fix%20%22it%22%0Anow%20%3D%20100%25%20%C3%A9&"))
    }

    @Test func theDocumentedExampleHasTheSameShape() throws {
        let url = try #require(ConductorURL.build(prompt: "Fix the login bug", folder: "/Users/jane/code/my-app"))
        #expect(url.absoluteString == "conductor://prompt=Fix%20the%20login%20bug&path=%2FUsers%2Fjane%2Fcode%2Fmy-app")
    }
}

@MainActor
struct SupersetConductorModelTests {
    private let file = URL(fileURLWithPath: "/Users/me/waggle/docs/My PRD.md")

    private func model(
        path: String, home: String = "/nonexistent-home", runner: FakeCLIRunner = FakeCLIRunner(),
        opener: FakeOpener = FakeOpener(), store: LaunchTargetStoring = FakeStore(),
        board: NSPasteboard = NSPasteboard(name: NSPasteboard.Name("knock-test-\(UUID().uuidString)"))
    ) -> IdeaLaunchHarness {
        let m = IdeaLaunchHarness(
            fileURL: file, sessions: [], sendPrompt: { _, _ in SendPromptResult(sent: true) }, launcher: NoTerminal(),
            resolvePath: { LoginShellPathResolution(path: path, shellSucceeded: true) }, pasteboard: board,
            opener: opener, launchTargetStore: store, sleep: { _ in }, cliRunner: runner, homeDirectory: home,
            folderPicker: { _ in nil })
        m.folder = URL(fileURLWithPath: "/Users/me/waggle")
        return m
    }

    @Test func menuOrderPutsSupersetThenConductorAfterTheApps() {
        #expect(LaunchTarget.allCases == [
            .claudeTerminal, .codexTerminal, .claudeApp, .codexApp, .claudeSuperset, .codexSuperset, .conductor, .claudeT3, .codexT3,
        ])
        #expect(LaunchTarget.claudeSuperset.agentName == "Claude Code")
        #expect(LaunchTarget.claudeSuperset.whereLabel == "in Superset")
        #expect(LaunchTarget.codexSuperset.agentName == "Codex")
        #expect(LaunchTarget.codexSuperset.whereLabel == "in Superset")
        #expect(LaunchTarget.conductor.agentName == "In Conductor")
        #expect(LaunchTarget.conductor.whereLabel == "Prompt filled in, you press Enter")
        #expect(LaunchTarget.claudeSuperset.mainLabel == "Start in Superset")
        #expect(LaunchTarget.conductor.mainLabel == "Start in Conductor")
    }

    @Test func greyedRowsShowTheirReason() {
        var a = LaunchAvailability.allAvailable
        #expect(a.unavailableText(.claudeSuperset) == nil)
        a.superset = .blocked(.signIn)
        a.conductor = false
        #expect(a.unavailableText(.claudeSuperset) == "Sign in to Superset first")
        #expect(a.unavailableText(.codexSuperset) == "Sign in to Superset first")
        #expect(a.unavailableText(.conductor) == "Not on this Mac")
        a.codexApp = false
        #expect(a.unavailableText(.codexApp) == "Not on this Mac")
    }

    @Test func detectFindsConductorByItsScheme() throws {
        let opener = FakeOpener()
        #expect(!LaunchAvailability.detect(searchPath: "/nonexistent-knock", opener: opener, homeDirectory: "/nonexistent-home").conductor)
        opener.conductorInstalled = true
        #expect(LaunchAvailability.detect(searchPath: "/nonexistent-knock", opener: opener, homeDirectory: "/nonexistent-home").conductor)
    }

    @Test func aSavedSupersetDefaultFallsBackWhenSupersetCannotWork() async throws {
        let bin = try makeBin()
        defer { try? FileManager.default.removeItem(at: bin) }
        let claude = bin.appendingPathComponent("claude")
        try "#!/bin/sh\n".write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        let runner = FakeCLIRunner()
        runner.stub("projects list", CLIResult(exitCode: 1, stdout: "", stderr: "Not logged in"))
        let store = FakeStore(.codexSuperset)
        let m = model(path: bin.path, runner: runner, store: store)
        #expect(m.launchTarget == .codexSuperset)
        await m.loadAvailability()
        #expect(m.availability.superset == .blocked(.signIn))
        #expect(m.launchTarget == .claudeTerminal)
        m.chooseLaunchTarget(.claudeSuperset)
        #expect(m.launchTarget != .claudeSuperset)
        #expect(store.load() == .codexSuperset)
    }

    @Test func aSavedSupersetDefaultStaysWhenSupersetWorks() async throws {
        let bin = try makeBin()
        defer { try? FileManager.default.removeItem(at: bin) }
        let runner = FakeCLIRunner()
        runner.stub("projects list", ok("[{\"id\":\"p-1\",\"path\":\"/Users/me/waggle\"}]"))
        let m = model(path: bin.path, runner: runner, store: FakeStore(.claudeSuperset))
        await m.loadAvailability()
        #expect(m.launchTarget == .claudeSuperset)
        #expect(m.availability.superset == .ready)
    }

    @Test func submitStartsTheSupersetWorkspaceWithAgentAndPrompt() async throws {
        let bin = try makeBin()
        defer { try? FileManager.default.removeItem(at: bin) }
        let runner = FakeCLIRunner()
        runner.stub("projects list", ok("[{\"id\":\"p-1\",\"path\":\"/Users/me/waggle\"}]"))
        runner.stub("ws create", ok("w-1"))
        runner.stub("ws open", ok(""))
        let m = model(path: bin.path, runner: runner)
        m.chooseLaunchTarget(.codexSuperset)
        var finished = false
        m.onFinish = { finished = true }
        await m.submit()
        #expect(finished)
        let create = try #require(runner.calls.first { $0.arguments.starts(with: ["ws", "create"]) })
        #expect(create.arguments.contains("--agent") && create.arguments.contains("codex"))
        #expect(create.arguments.last == "--quiet")
        #expect(create.arguments.contains(m.prompt))
    }

    @Test func supersetFailureKeepsTheSheetOpenWithAMessage() async throws {
        let bin = try makeBin()
        defer { try? FileManager.default.removeItem(at: bin) }
        let runner = FakeCLIRunner()
        runner.stub("projects list", ok("[]"))
        let m = model(path: bin.path, runner: runner)
        m.chooseLaunchTarget(.claudeSuperset)
        var finished = false
        m.onFinish = { finished = true }
        await m.submit()
        #expect(!finished)
        #expect(m.errorText == "Add this folder in Superset first. Then try again, or copy the prompt instead.")
    }

    @Test func conductorOpensTheLinkAndCopiesThePrompt() async throws {
        let opener = FakeOpener()
        opener.conductorInstalled = true
        let board = NSPasteboard(name: NSPasteboard.Name("knock-test-\(UUID().uuidString)"))
        let m = model(path: "/nonexistent-knock", opener: opener, board: board)
        m.chooseLaunchTarget(.conductor)
        var finished = false
        m.onFinish = { finished = true }
        await m.submit()
        #expect(finished)
        #expect(opener.opened.count == 1)
        #expect(opener.opened[0] == ConductorURL.build(prompt: m.prompt, folder: "/Users/me/waggle"))
        #expect(board.string(forType: .string) == m.prompt)
    }

    @Test func conductorFailureTellsTheOperatorThePromptIsOnTheClipboard() async {
        let opener = FakeOpener()
        opener.openSucceeds = false
        let m = model(path: "/nonexistent-knock", opener: opener)
        m.chooseLaunchTarget(.conductor)
        var finished = false
        m.onFinish = { finished = true }
        await m.submit()
        #expect(!finished)
        #expect(m.errorText == "Waggle could not open Conductor. The prompt is on your clipboard.")
    }
}

// WAG-269: New idea uses the same targets, greyed reasons and fallbacks as Start from a document.
@MainActor
struct NewIdeaLaunchTargetTests {
    private func idea(
        path: String, runner: FakeCLIRunner = FakeCLIRunner(), opener: FakeOpener = FakeOpener(),
        store: FakeStore = FakeStore(), board: NSPasteboard = NSPasteboard(name: .init("knock-idea-\(UUID().uuidString)"))
    ) -> NewIdeaModel {
        let launcher = SessionLauncher(
            launcher: NoTerminal(), resolvePath: { LoginShellPathResolution(path: path, shellSucceeded: true) }, pasteboard: board,
            opener: opener, launchTargetStore: store, cliRunner: runner, homeDirectory: "/nonexistent-home")
        return NewIdeaModel(
            launcher: launcher, defaults: UserDefaults(suiteName: "new-idea-\(UUID().uuidString)")!,
            homeDirectory: URL(fileURLWithPath: "/Users/me/waggle"), folderPicker: { _ in nil }, filePicker: { [] })
    }

    @Test func aSavedSupersetPickFallsBackWithItsGreyedReason() async throws {
        let bin = try makeBin()
        defer { try? FileManager.default.removeItem(at: bin) }
        let claude = bin.appendingPathComponent("claude")
        try "#!/bin/sh\n".write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        let runner = FakeCLIRunner()
        runner.stub("projects list", CLIResult(exitCode: 1, stdout: "", stderr: "Not logged in"))
        let m = idea(path: bin.path, runner: runner, store: FakeStore(.codexSuperset))
        await m.loadAvailability()
        #expect(m.launcher.availability.unavailableText(.codexSuperset) == "Sign in to Superset first")
        #expect(m.launcher.launchTarget == .claudeTerminal)
        m.launcher.chooseLaunchTarget(.claudeSuperset)
        #expect(m.launcher.launchTarget != .claudeSuperset)
    }

    @Test func startOpensTheSupersetWorkspaceNamedFromTheIdea() async throws {
        let bin = try makeBin()
        defer { try? FileManager.default.removeItem(at: bin) }
        let runner = FakeCLIRunner()
        runner.stub("projects list", ok("[{\"id\":\"p-1\",\"path\":\"/Users/me/waggle\"}]"))
        runner.stub("ws create", ok("w-1"))
        runner.stub("ws open", ok(""))
        let m = idea(path: bin.path, runner: runner)
        await m.loadAvailability()
        m.launcher.chooseLaunchTarget(.claudeSuperset)
        m.idea = "\nCheaper onboarding\nmore detail"
        await m.start()
        let create = try #require(runner.calls.first { $0.arguments.starts(with: ["ws", "create"]) })
        #expect(create.arguments.contains("Cheaper onboarding"))
        #expect(m.idea == "")
        #expect(m.errorText == nil)
    }

    @Test func conductorOpensTheLinkAndCopiesThePrompt() async {
        let opener = FakeOpener()
        opener.conductorInstalled = true
        let board = NSPasteboard(name: .init("knock-idea-\(UUID().uuidString)"))
        let m = idea(path: "/nonexistent-knock", opener: opener, board: board)
        await m.loadAvailability()
        m.launcher.chooseLaunchTarget(.conductor)
        m.idea = "An idea"
        let prompt = m.prompt
        await m.start()
        #expect(opener.opened.count == 1)
        #expect(board.string(forType: .string) == prompt)
    }

    @Test func aFailedLaunchKeepsTheIdeaAndShowsTheReason() async {
        let opener = FakeOpener()
        opener.conductorInstalled = true
        opener.openSucceeds = false
        let m = idea(path: "/nonexistent-knock", opener: opener)
        await m.loadAvailability()
        m.launcher.chooseLaunchTarget(.conductor)
        m.idea = "An idea"
        await m.start()
        #expect(m.idea == "An idea")
        #expect(m.errorText == "Waggle could not open Conductor. The prompt is on your clipboard.")
    }
}

// WAG-319: comparing project folders must not touch the disk for a protected folder. A symlink
// lookup under Documents or Desktop makes macOS ask for access again and again.
@Suite struct ProjectPathNormalizationTests {
    let home = "/Users/me"

    @Test func protectedFoldersAreComparedAsText() {
        #expect(SupersetCommand.normalizedPath("/Users/me/Documents/app/", home: home) == "/Users/me/Documents/app")
        #expect(SupersetCommand.normalizedPath("/Users/me/Documents/x/../app/./", home: home) == "/Users/me/Documents/app")
        #expect(SupersetCommand.normalizedPath("/Users/me/Desktop/a", home: home) == "/Users/me/Desktop/a")
        #expect(SupersetCommand.normalizedPath("/Users/me/Library/Mobile Documents/x", home: home) == "/Users/me/Library/Mobile Documents/x")
    }

    @Test func aSymlinkInsideDocumentsIsNotFollowed() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("wag319-\(UUID().uuidString)")
        let documents = dir.appendingPathComponent("Documents")
        try fm.createDirectory(at: documents.appendingPathComponent("real"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try fm.createSymbolicLink(at: documents.appendingPathComponent("link"), withDestinationURL: documents.appendingPathComponent("real"))
        let link = documents.appendingPathComponent("link").path
        #expect(SupersetCommand.normalizedPath(link, home: dir.path).hasSuffix("/Documents/link"))
    }

    @Test func otherFoldersStillResolveSymlinks() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("wag319-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("real"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: dir.appendingPathComponent("real"))
        #expect(SupersetCommand.normalizedPath(dir.appendingPathComponent("link").path, home: "/Users/me").hasSuffix("/real"))
    }
}
