import AppKit
import Foundation
import Testing
@testable import Knock

// WAG-271: launch and send tests, driven through a harness over the shared launcher. No test opens Terminal or starts claude: a fake launcher stands in.

private final class FakeLauncher: TerminalLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [String] = []
    var launched: [String] { lock.lock(); defer { lock.unlock() }; return scripts }
    func launch(script: String) throws { lock.lock(); scripts.append(script); lock.unlock() }
}

// WAG-254: fakes for the app opener and the saved-default store. No test opens a real app, a
// real URL, or touches the real UserDefaults domain.

private final class FakeAppOpener: ExternalAppOpening, @unchecked Sendable {
    private let lock = NSLock()
    var installedBundleIDs: Set<String> = []
    var schemeAppURL: URL?
    var openSucceeds = true
    /// `isRunning` reports false for this many checks, then true (simulates a cold app start).
    var runningAfterChecks = 0
    private var checks = 0
    private var _launchedApps: [URL] = []
    private var _openedURLs: [URL] = []
    var launchedApps: [URL] { lock.lock(); defer { lock.unlock() }; return _launchedApps }
    var openedURLs: [URL] { lock.lock(); defer { lock.unlock() }; return _openedURLs }

    func isAppInstalled(bundleIdentifier: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return installedBundleIDs.contains(bundleIdentifier)
    }
    func appURL(toOpen url: URL) -> URL? { lock.lock(); defer { lock.unlock() }; return schemeAppURL }
    func isRunning(appURL: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        checks += 1
        return checks > runningAfterChecks
    }
    func launchApp(at appURL: URL) { lock.lock(); _launchedApps.append(appURL); lock.unlock() }
    func open(url: URL) -> Bool {
        lock.lock(); _openedURLs.append(url); defer { lock.unlock() }
        return openSucceeds
    }
}

private final class FakeLaunchTargetStore: LaunchTargetStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: LaunchTarget?
    init(initial: LaunchTarget? = nil) { stored = initial }
    func load() -> LaunchTarget? { lock.lock(); defer { lock.unlock() }; return stored }
    func save(_ target: LaunchTarget) { lock.lock(); stored = target; lock.unlock() }
}

@MainActor
struct SessionLauncherTests {
    private let file = URL(fileURLWithPath: "/tmp/docs/My PRD.md")

    private func model(
        launcher: TerminalLaunching = FakeLauncher(),
        path: String = "/bin",
        pasteboard: NSPasteboard = NSPasteboard(name: NSPasteboard.Name("knock-test-\(UUID().uuidString)")),
        opener: ExternalAppOpening = FakeAppOpener(),
        store: LaunchTargetStoring = FakeLaunchTargetStore(),
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { _ in }
    ) -> LaunchHarness {
        LaunchHarness(
            fileURL: file, launcher: launcher,
            resolvePath: { LoginShellPathResolution(path: path, shellSucceeded: true) }, pasteboard: pasteboard,
            opener: opener, launchTargetStore: store, sleep: sleep)
    }

    @Test func templatesPerGoal() {
        let p = "/tmp/a.md"
        #expect(DocumentPrompt.build(idea: "Auth", paths: [p], goal: .decisions)
            == "My idea:\nAuth\n\nAttached files:\n- /tmp/a.md\n\nRead the idea and the attached files. Find the open decisions in it and ask me in Waggle, one at a time, with options and your recommendation.")
        #expect(DocumentPrompt.build(idea: "Auth", paths: [p], goal: .pen).contains("Draw the key screens with a design tool you have"))
        #expect(DocumentPrompt.build(idea: "Auth", paths: [p], goal: .pen).contains("Use the design kit from Waggle's guide if there is one."))
        #expect(!DocumentPrompt.build(idea: "Auth", paths: [p], goal: .prototype).contains("design kit"))
        #expect(DocumentPrompt.build(idea: "", paths: [p], goal: .prototype).contains("clickable prototype"))
        #expect(DocumentPrompt.build(idea: "x", paths: [p], goal: .review).contains("unclear or missing"))
    }

    @Test func pathsWithSpacesAndQuotes() {
        #expect(DocumentPrompt.build(idea: "t", paths: ["/a b/it's \"x\".md"], goal: .review).contains("- \"/a b/it's \"x\".md\""))
    }

    @Test func newSessionGoesThroughTheFakeLauncher() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("knock-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fakeClaude = dir.appendingPathComponent("claude")
        try "#!/bin/sh\n".write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)

        let launcher = FakeLauncher()
        let m = model(launcher: launcher, path: dir.path)
        m.idea = "It's \"mine\""
        let expectedPrompt = m.prompt
        var finished = false
        m.onFinish = { finished = true }
        await m.submit()
        #expect(finished)
        #expect(launcher.launched.count == 1)
        let script = launcher.launched[0]
        #expect(script.contains(NewSessionCommand.shellQuote(fakeClaude.path)))
        #expect(script.contains(NewSessionCommand.shellQuote(expectedPrompt)))
        #expect(script.contains("cd -- '/tmp/docs'"))
    }

    @Test func missingClaudeShowsAnErrorAndLaunchesNothing() async {
        let launcher = FakeLauncher()
        let m = model(launcher: launcher, path: "/nonexistent-knock-dir")
        var finished = false
        m.onFinish = { finished = true }
        await m.submit()
        #expect(!finished)
        #expect(launcher.launched.isEmpty)
        #expect(m.errorText?.contains("Copy the prompt") == true)
    }

    // MARK: WAG-254: choose the agent and where it opens

    @Test func mainLabelsAndMetaLinePerPick() {
        #expect(LaunchTarget.claudeTerminal.mainLabel == "Start in Terminal")
        #expect(LaunchTarget.codexTerminal.mainLabel == "Start in Terminal")
        #expect(LaunchTarget.claudeApp.mainLabel == "Start in the Claude app")
        #expect(LaunchTarget.codexApp.mainLabel == "Start in the Codex app")

        #expect(LaunchTarget.claudeTerminal.metaLine(folder: "Desktop") == "Opens Terminal in Desktop and starts Claude Code.")
        #expect(LaunchTarget.codexTerminal.metaLine(folder: "Desktop") == "Opens Terminal in Desktop and starts Codex.")
        #expect(LaunchTarget.claudeApp.metaLine(folder: "Desktop") == "Opens the Claude app in Desktop with your prompt typed.")
        #expect(LaunchTarget.codexApp.metaLine(folder: "Desktop") == "Opens the Codex app in Desktop with your prompt typed.")

        #expect(LaunchTarget.claudeTerminal.agentName == "Claude Code")
        #expect(LaunchTarget.codexApp.agentName == "Codex")
        #expect(LaunchTarget.claudeApp.whereLabel == "in the Claude app")
        #expect(LaunchTarget.codexTerminal.whereLabel == "in Terminal")
    }

    @Test func modelReflectsTheChosenLaunchTargetInTitleAndMeta() {
        let m = model()
        m.chooseLaunchTarget(.codexApp)
        #expect(m.launchTarget.mainLabel == "Start in the Codex app")
        #expect(m.launchTarget.metaLine(folder: m.folder.lastPathComponent) == "Opens the Codex app in docs with your prompt typed.")
    }

    @Test func claudeAppURLRoundTrips() {
        let prompt = "Read \"a b\".md & go"
        let folderPath = "/Users/me/My Project"
        guard let url = ClaudeAppURL.build(prompt: prompt, folder: folderPath) else {
            Issue.record("expected a url")
            return
        }
        #expect(url.absoluteString.hasPrefix("claude://code/new?"))
        #expect(!url.absoluteString.contains(" "))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first(where: { $0.name == "q" })?.value == prompt)
        #expect(items.first(where: { $0.name == "folder" })?.value == folderPath)
    }

    @Test func claudeAppFitsRespectsTheAppsCap() {
        #expect(ClaudeAppURL.fits(prompt: String(repeating: "a", count: ClaudeAppURL.maxPromptLength)))
        #expect(!ClaudeAppURL.fits(prompt: String(repeating: "a", count: ClaudeAppURL.maxPromptLength + 1)))
    }

    @Test func codexAppURLRoundTrips() {
        let prompt = "Build the thing & ship it"
        let folderPath = "/tmp/a b"
        guard let url = CodexAppURL.build(prompt: prompt, folder: folderPath) else {
            Issue.record("expected a url")
            return
        }
        #expect(url.absoluteString.hasPrefix("codex://threads/new?"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first(where: { $0.name == "prompt" })?.value == prompt)
        #expect(items.first(where: { $0.name == "path" })?.value == folderPath)
    }

    @Test func codexScriptRunsCodexInTheSameShapeOfScript() {
        let script = NewSessionCommand.codexScript(folder: "/tmp/a b", prompt: "hi", codexPath: "/bin/codex", searchPath: "/bin")
        #expect(script.contains("exec '/bin/codex' " + NewSessionCommand.shellQuote("hi")))
        #expect(script.contains("cd -- '/tmp/a b' || exit 1"))
        #expect(script.hasPrefix("#!/bin/zsh\n"))
    }

    @Test func findExecutableGeneralizesFindClaudeAndFindCodex() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("knock-exec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let codex = dir.appendingPathComponent("codex")
        try "#!/bin/sh\n".write(to: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
        #expect(NewSessionCommand.findCodex(searchPath: dir.path) == codex.path)
        #expect(NewSessionCommand.findClaude(searchPath: dir.path) == nil)
    }

    @Test func detectsEachTargetsAvailability() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("knock-avail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let claude = dir.appendingPathComponent("claude")
        try "#!/bin/sh\n".write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)

        let opener = FakeAppOpener()
        opener.installedBundleIDs = [LaunchAvailability.claudeAppBundleID]

        let result = LaunchAvailability.detect(searchPath: dir.path, opener: opener)
        #expect(result.claudeTerminal)
        #expect(!result.codexTerminal)
        #expect(result.claudeApp)
        #expect(!result.codexApp)
    }

    @Test func loadAvailabilityFallsBackWhenTheSavedDefaultIsMissing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("knock-avail2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let claude = dir.appendingPathComponent("claude")
        try "#!/bin/sh\n".write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)

        let store = FakeLaunchTargetStore(initial: .codexApp)
        let opener = FakeAppOpener()
        let m = model(path: dir.path, opener: opener, store: store)
        #expect(m.launchTarget == .codexApp)
        await m.loadAvailability()
        #expect(m.launchTarget == .claudeTerminal)
        #expect(m.availability.claudeTerminal)
        #expect(!m.availability.codexApp)
    }

    @Test func anUnavailableTargetCannotBeChosen() async {
        let opener = FakeAppOpener()
        let m = model(path: "/nonexistent-knock-dir", opener: opener)
        await m.loadAvailability()
        #expect(!m.availability.codexApp)
        let before = m.launchTarget
        m.chooseLaunchTarget(.codexApp)
        #expect(m.launchTarget == before)
    }

    @Test func choosingALaunchTargetChangesThisRunOnly() {
        let store = FakeLaunchTargetStore()
        let m = model(store: store)
        m.chooseLaunchTarget(.codexTerminal)
        #expect(m.launchTarget == .codexTerminal)
        #expect(m.launcher.defaultTarget == .claudeTerminal)
        #expect(m.launcher.differsFromDefault)
        #expect(store.load() == nil)
        #expect(model(store: store).launchTarget == .claudeTerminal)
    }

    @Test func useAsMyDefaultSavesThePick() {
        let store = FakeLaunchTargetStore()
        let m = model(store: store)
        m.chooseLaunchTarget(.codexTerminal)
        m.launcher.useCurrentAsDefault()
        #expect(store.load() == .codexTerminal)
        #expect(m.launcher.defaultTarget == .codexTerminal)
        #expect(!m.launcher.differsFromDefault)
        #expect(model(store: store).launchTarget == .codexTerminal)
    }

    @Test func chipLabelPerTargetAndChangedState() {
        let labels: [LaunchTarget: String] = [
            .claudeTerminal: "Claude Code · Terminal", .codexTerminal: "Codex · Terminal",
            .claudeApp: "Claude Code · Claude app", .codexApp: "Codex · Codex app",
            .claudeSuperset: "Claude Code · Superset", .codexSuperset: "Codex · Superset",
            .claudeT3: "Claude Code · T3 Code", .codexT3: "Codex · T3 Code", .conductor: "Conductor",
        ]
        #expect(Set(labels.keys) == Set(LaunchTarget.allCases))
        for (target, label) in labels { #expect(target.chipLabel == label) }
        let m = model()
        #expect(m.launchTarget.chipLabel == "Claude Code · Terminal")
        #expect(!m.launcher.differsFromDefault)
        m.chooseLaunchTarget(.claudeApp)
        #expect(m.launchTarget.chipLabel == "Claude Code · Claude app")
        #expect(m.launcher.differsFromDefault)
        m.chooseLaunchTarget(.claudeTerminal)
        #expect(!m.launcher.differsFromDefault)
    }

    @Test func theNextIdeaStartsFromTheDefaultAfterAStart() async {
        let store = FakeLaunchTargetStore()
        let m = model(store: store)
        m.chooseLaunchTarget(.claudeApp)
        await m.submit()
        #expect(m.launchTarget == .claudeTerminal)
        #expect(m.launchTarget.chipLabel == "Claude Code · Terminal")
        #expect(store.load() == nil)
    }

    @Test func aFailedStartKeepsThePick() async {
        let m = model(path: "/nonexistent-knock-dir")
        m.chooseLaunchTarget(.codexTerminal)
        await m.submit()
        #expect(m.errorText != nil)
        #expect(m.launchTarget == .codexTerminal)
    }

    @Test func greyedTargetsKeepTheirReason() async {
        let m = model(path: "/nonexistent-knock-dir")
        await m.loadAvailability()
        #expect(!m.availability.codexApp)
        #expect(m.availability.unavailableText(.codexApp) != nil)
        m.chooseLaunchTarget(.codexApp)
        #expect(m.launchTarget != .codexApp)
        #expect(!m.launcher.differsFromDefault || m.launchTarget != m.launcher.defaultTarget)
    }

    @Test func userDefaultsStoreRoundTripsOneKey() {
        let suite = "knock-test-launch-target-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("expected a user defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsLaunchTargetStore(defaults: defaults)
        #expect(store.load() == nil)
        store.save(.codexApp)
        #expect(store.load() == .codexApp)
        #expect(defaults.string(forKey: UserDefaultsLaunchTargetStore.key) == LaunchTarget.codexApp.rawValue)
    }

    @Test func claudeAppOpensDirectlyAndFinishes() async {
        let opener = FakeAppOpener()
        let m = model(opener: opener)
        m.chooseLaunchTarget(.claudeApp)
        var finished = false
        m.onFinish = { finished = true }
        await m.submit()
        #expect(finished)
        #expect(opener.openedURLs.count == 1)
        #expect(opener.openedURLs[0].scheme == "claude")
    }

    @Test func claudeAppFallsBackToTerminalWhenThePromptIsTooLong() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("knock-claude2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let claude = dir.appendingPathComponent("claude")
        try "#!/bin/sh\n".write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)

        let launcher = FakeLauncher()
        let opener = FakeAppOpener()
        let m = model(launcher: launcher, path: dir.path, opener: opener)
        m.chooseLaunchTarget(.claudeApp)
        m.idea = String(repeating: "x", count: ClaudeAppURL.maxPromptLength + 500)
        var finished = false
        m.onFinish = { finished = true }
        await m.submit()
        #expect(!finished)
        #expect(launcher.launched.count == 1)
        #expect(opener.openedURLs.isEmpty)
        #expect(m.errorText?.contains("too long") == true)
    }

    @Test func codexAppLaunchesTheAppFirstWhenNotRunningThenOpensAndCopiesThePrompt() async {
        let opener = FakeAppOpener()
        opener.schemeAppURL = URL(fileURLWithPath: "/Applications/Codex.app")
        opener.runningAfterChecks = 2
        let board = NSPasteboard(name: NSPasteboard.Name("knock-test-\(UUID().uuidString)"))
        let m = model(pasteboard: board, opener: opener)
        m.chooseLaunchTarget(.codexApp)
        let expectedPrompt = m.prompt
        var finished = false
        m.onFinish = { finished = true }
        await m.submit()
        #expect(finished)
        #expect(opener.launchedApps.count == 1)
        #expect(opener.openedURLs.count == 1)
        #expect(opener.openedURLs[0].absoluteString.hasPrefix("codex://threads/new?"))
        #expect(board.string(forType: .string) == expectedPrompt)
    }

    @Test func codexAppOpensWithoutLaunchingWhenAlreadyRunning() async {
        let opener = FakeAppOpener()
        opener.schemeAppURL = URL(fileURLWithPath: "/Applications/Codex.app")
        opener.runningAfterChecks = 0
        let m = model(opener: opener)
        m.chooseLaunchTarget(.codexApp)
        var finished = false
        m.onFinish = { finished = true }
        await m.submit()
        #expect(finished)
        #expect(opener.launchedApps.isEmpty)
        #expect(opener.openedURLs.count == 1)
    }

}
