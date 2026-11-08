import AppKit
import Foundation
import Testing
@testable import Knock

// WAG-271: launch and send tests, driven through the New idea model. No test opens Terminal or starts claude: a fake launcher stands in.

private final class FakeLauncher: TerminalLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [String] = []
    var launched: [String] { lock.lock(); defer { lock.unlock() }; return scripts }
    func launch(script: String) throws { lock.lock(); scripts.append(script); lock.unlock() }
}

private actor SendLog {
    var calls: [(String, String)] = []
    func add(_ id: String, _ text: String) { calls.append((id, text)) }
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
    private func session(
        _ id: String, runtime: Runtime = .claude, state: SessionState = .live, canNudge: Bool = true,
        cwd: String = "/Users/me/proj", growing: Bool? = nil
    ) -> SessionInfo {
        let context = growing.map {
            SessionContext(
                title: nil, goal: nil, said: nil, lastAction: nil, lastActionAt: nil, recent: [],
                plan: nil, changes: nil, growing: $0, live: nil)
        }
        return SessionInfo(
            id: id, runtime: runtime, taskName: "Task \(id)", project: "knock", branch: nil, cwd: cwd,
            canNudge: canNudge, state: state, connectedAt: "2026-10-05T09:00:00.000Z",
            lastSeenAt: "2026-10-05T09:55:00.000Z", context: context)
    }

    private func sessionNamed(_ id: String, project: String) -> SessionInfo {
        SessionInfo(
            id: id, runtime: .claude, taskName: "Task \(id)", project: project, branch: nil, cwd: "/Users/me/\(project)",
            canNudge: true, state: .live, connectedAt: "2026-10-05T09:00:00.000Z",
            lastSeenAt: "2026-10-05T09:55:00.000Z", context: nil)
    }

    private let now = KnockDateFormat.date(from: "2026-10-05T10:00:00.000Z")!
    private let file = URL(fileURLWithPath: "/tmp/docs/My PRD.md")

    private func model(
        sessions: [SessionInfo] = [],
        launcher: TerminalLaunching = FakeLauncher(),
        path: String = "/bin",
        pasteboard: NSPasteboard = NSPasteboard(name: NSPasteboard.Name("knock-test-\(UUID().uuidString)")),
        send: @escaping @Sendable (String, String) async throws -> SendPromptResult = { _, _ in SendPromptResult(sent: true) },
        folderPicker: @escaping @MainActor (URL) -> URL? = { _ in nil },
        opener: ExternalAppOpening = FakeAppOpener(),
        store: LaunchTargetStoring = FakeLaunchTargetStore(),
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { _ in }
    ) -> IdeaLaunchHarness {
        IdeaLaunchHarness(
            fileURL: file, sessions: sessions, now: now, sendPrompt: send, launcher: launcher,
            resolvePath: { LoginShellPathResolution(path: path, shellSucceeded: true) }, pasteboard: pasteboard,
            opener: opener, launchTargetStore: store, sleep: sleep, folderPicker: folderPicker)
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

    @Test func topicDefaultsToFileNameWithoutExtension() {
        #expect(model().model.topic == "My PRD")
        let m = model()
        m.model.removeAttachment(file)
        m.model.receive(files: [URL(fileURLWithPath: "/x/plan.v2.docx")])
        m.model.removeAttachment(file)
        #expect(m.model.topic == "plan.v2")
    }

    @Test func onlyLiveClaudeSessionsThatCanNudgeAreListed() {
        let m = model(sessions: [
            session("a"), session("b", canNudge: false), session("c", runtime: .codex),
            session("d", state: .ended), session("e", growing: true),
        ])
        #expect(m.model.sessionOptions.map(\.id) == [.session("a"), .session("e")])
        #expect(m.model.sessionOptions[0].statusWord == "idle")
        #expect(m.model.sessionOptions[0].folder == "/Users/me/proj")
    }

    @Test func newSessionIsTheDefaultEvenWithRunningSessions() {
        let m = model(sessions: [session("a")])
        #expect(m.model.target == .newSession)
        #expect(m.model.startLabel == "Start planning")
    }

    @Test func pickingASessionRetitlesTheButtonAndAFolderOrLaunchPickGoesBack() {
        let m = model(sessions: [session("a"), session("e")])
        m.model.chooseSession(.session("e"))
        #expect(m.model.startLabel == "Send to Knock")
        m.model.chooseNewSession()
        #expect(m.model.target == .newSession)
        #expect(m.model.startLabel == "Start planning")
        m.model.chooseSession(.session("a"))
        m.model.chooseFolder(URL(fileURLWithPath: "/Users/me/Desktop"))
        #expect(m.model.target == .newSession)
    }

    @Test func aPickedSessionThatGoesAwayFallsBackToANewSession() {
        let m = model(sessions: [session("a"), session("e")])
        m.model.chooseSession(.session("e"))
        m.model.updateSessions([session("a")], cases: [], now: now)
        #expect(m.model.target == .newSession)
        #expect(m.model.sessionOptions.map(\.id) == [.session("a")])
    }

    @Test func noRunningSessionsMeansNoOptions() {
        #expect(model().model.sessionOptions.isEmpty)
    }

    @Test func projectNamesAreCleanedLikeTheQueue() {
        let sessions = [
            sessionNamed("a", project: "fragrant-hospital-fc8f1973"),
            sessionNamed("b", project: "my_cool-app"),
            sessionNamed("c", project: "Syllotips"),
        ]
        let m = model(sessions: sessions)
        #expect(m.model.sessionOptions.map(\.name) == ["Fragrant hospital", "My cool app", "Syllotips"])
        for option in m.model.sessionOptions {
            #expect(!option.name.contains("Claude Code"))
            #expect(!option.name.contains("/"))
        }
        m.model.chooseSession(.session("a"))
        #expect(m.model.startLabel == "Send to Fragrant hospital")
    }

    @Test func folderNameShowsInsteadOfThePath() {
        let m = model()
        #expect(m.model.folderName == "docs")
        m.model.chooseFolder(URL(fileURLWithPath: "/Users/me/Desktop"))
        #expect(m.model.folderName == "Desktop")
        #expect(m.launchTarget.metaLine(folder: m.model.folderName) == "Opens Terminal in Desktop and starts Claude Code.")
    }

    @Test func folderChipOpensThePickerAtTheCurrentFolder() {
        var openedAt: URL?
        let m = model(folderPicker: { start in
            openedAt = start
            return URL(fileURLWithPath: "/Users/me/Desktop")
        })
        m.model.pickFolder()
        #expect(openedAt?.path == "/tmp/docs")
        #expect(m.model.folderName == "Desktop")
    }

    @Test func cancelledPickerKeepsTheFolder() {
        let m = model(folderPicker: { _ in nil })
        m.model.pickFolder()
        #expect(m.model.folderName == "docs")
    }

    @Test func designsGoalCopy() {
        #expect(DocumentGoal.pen.title == "Screens to look at")
        #expect(DocumentGoal.pen.detail == "Draw the key screens with any tool it has, or as images, and send them for review.")
    }

    @Test func sendUsesTheRpcWithTheIdeaAndFilesAndClearsTheBox() async {
        let log = SendLog()
        let m = model(sessions: [session("a")], send: { id, text in await log.add(id, text); return SendPromptResult(sent: true) })
        m.model.idea = "Try a dark mode"
        m.model.chooseSession(.session("a"))
        let expected = m.model.prompt
        var finished = false
        m.onFinish = { finished = true }
        await m.submit()
        let calls = await log.calls
        #expect(calls.count == 1)
        #expect(calls[0].0 == "a")
        #expect(calls[0].1 == expected)
        #expect(calls[0].1.contains("Try a dark mode"))
        #expect(calls[0].1.contains("/tmp/docs/My PRD.md"))
        #expect(finished)
        #expect(m.errorText == nil)
        #expect(m.model.idea.isEmpty)
    }

    @Test func sendingToASessionNeverRunsTheLaunchTarget() async {
        let launcher = FakeLauncher()
        let opener = FakeAppOpener()
        let m = model(sessions: [session("a")], launcher: launcher, opener: opener)
        m.model.chooseSession(.session("a"))
        await m.submit()
        #expect(launcher.launched.isEmpty)
        #expect(opener.openedURLs.isEmpty)
    }

    @Test func failedSendShowsAPlainErrorAndKeepsTheIdea() async {
        let m = model(sessions: [session("a")], send: { _, _ in SendPromptResult(sent: false, reason: .sessionClosed) })
        m.model.idea = "Keep me"
        m.model.chooseSession(.session("a"))
        var finished = false
        m.onFinish = { finished = true }
        await m.submit()
        #expect(!finished)
        #expect(m.errorText?.contains("closed") == true)
        #expect(m.errorText?.contains("—") == false)
        #expect(m.model.idea == "Keep me")
        #expect(m.model.attachments == [file])
    }

    @Test func aDropAttachesTheFilesSetsTheFolderAndAsksForFocus() {
        let m = model()
        let ticks = m.model.focusTick
        let a = URL(fileURLWithPath: "/Users/me/specs/a.png")
        let b = URL(fileURLWithPath: "/Users/me/other/b.pdf")
        m.model.receive(files: [a, b, URL(string: "https://x.com/a.md")!])
        #expect(m.model.attachments == [file, a, b])
        #expect(m.model.folder.path == "/Users/me/specs")
        #expect(m.model.focusTick == ticks + 1)
        m.model.receive(files: [])
        #expect(m.model.focusTick == ticks + 1)
    }

    @Test func aDropDoesNotSaveTheFolderAsTheDefault() {
        let suite = "knock-test-drop-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let m = NewIdeaModel(defaults: defaults, folderPicker: { _ in nil }, filePicker: { [] })
        m.receive(files: [URL(fileURLWithPath: "/Users/me/specs/a.png")])
        #expect(defaults.string(forKey: NewIdeaModel.folderKey) == nil)
    }

    @Test func shellQuoting() {
        #expect(NewSessionCommand.shellQuote("a b") == "'a b'")
        #expect(NewSessionCommand.shellQuote("it's") == "'it'\\''s'")
        let evil = "x'; rm -rf ~; echo '$(whoami) `id`"
        let script = NewSessionCommand.script(folder: "/tmp/a b", prompt: evil, claudePath: "/bin/claude", searchPath: "/bin")
        #expect(script.contains("exec '/bin/claude' " + NewSessionCommand.shellQuote(evil)))
        #expect(script.contains("cd -- '/tmp/a b' || exit 1"))
        #expect(script.hasPrefix("#!/bin/zsh\n"))
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
        m.model.idea = "It's \"mine\""
        let expectedPrompt = m.model.prompt
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
        #expect(m.launchTarget.metaLine(folder: m.model.folderName) == "Opens the Codex app in docs with your prompt typed.")
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
        m.model.useAsDefault()
        #expect(store.load() == .codexTerminal)
        #expect(m.launcher.defaultTarget == .codexTerminal)
        #expect(!m.launcher.differsFromDefault)
        #expect(m.model.pickIsDefault)
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
        #expect(m.model.chipLabel == "Claude Code · Terminal")
        #expect(!m.model.chipDiffersFromDefault)
        m.chooseLaunchTarget(.claudeApp)
        #expect(m.model.chipLabel == "Claude Code · Claude app")
        #expect(m.model.chipDiffersFromDefault)
        m.chooseLaunchTarget(.claudeTerminal)
        #expect(!m.model.chipDiffersFromDefault)
    }

    @Test func aRunningSessionPickShowsOnTheChipAndCannotBeTheDefault() {
        let m = model(sessions: [sessionNamed("s1", project: "waggle")])
        m.model.chooseSession(.session("s1"))
        #expect(m.model.chipLabel == "Waggle · Running session")
        #expect(m.model.chipDiffersFromDefault)
        #expect(!m.model.canUseAsDefault)
        m.model.useAsDefault()
        #expect(m.launcher.defaultTarget == .claudeTerminal)
    }

    @Test func theNextIdeaStartsFromTheDefaultAfterAStart() async {
        let store = FakeLaunchTargetStore()
        let m = model(store: store)
        m.chooseLaunchTarget(.claudeApp)
        await m.submit()
        #expect(m.launchTarget == .claudeTerminal)
        #expect(m.model.chipLabel == "Claude Code · Terminal")
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
        #expect(!m.model.chipDiffersFromDefault || m.launchTarget != m.launcher.defaultTarget)
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
        m.model.idea = String(repeating: "x", count: ClaudeAppURL.maxPromptLength + 500)
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
        let expectedPrompt = m.model.prompt
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
