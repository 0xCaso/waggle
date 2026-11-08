import AppKit
import Foundation

/// WAG-254 launch logic, used by the New idea page (WAG-255): which agent, where it opens, and the launch itself. It never reads a file.
@MainActor
final class SessionLauncher: ObservableObject {
    /// Which agent, and where it opens. Loaded from the saved default; `loadAvailability()` falls it
    /// back to the first available target.
    /// This run's pick. It starts from `defaultTarget` and goes back to it after a start.
    @Published private(set) var launchTarget: LaunchTarget
    /// The saved default (WAG-274). Only "Use as my default" changes it.
    @Published private(set) var defaultTarget: LaunchTarget
    @Published private(set) var availability = LaunchAvailability.allAvailable
    @Published private(set) var errorText: String?

    private let launcher: TerminalLaunching
    private let resolvePath: @Sendable () async -> LoginShellPathResolution
    private let pasteboard: NSPasteboard
    private let fileManager: FileManager
    private let opener: ExternalAppOpening
    private let launchTargetStore: LaunchTargetStoring
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let cliRunner: CLIRunning
    private let homeDirectory: String
    private let t3Secrets: SecretStoring
    private let t3Meta: T3MetaStoring
    private let t3Server: T3Serving
    private let environment: [String: String]
    private let isProcessAlive: @Sendable (Int) -> Bool
    private let clock: @Sendable () -> Date
    /// Bumped by each Superset check, so a slow older check cannot overwrite a newer one.
    private var supersetCheckID = 0

    init(
        launcher: TerminalLaunching = TerminalAppLauncher(),
        resolvePath: @escaping @Sendable () async -> LoginShellPathResolution = { await LoginShellPath.resolve() },
        pasteboard: NSPasteboard = .general,
        fileManager: FileManager = .default,
        opener: ExternalAppOpening = WorkspaceAppOpener(),
        launchTargetStore: LaunchTargetStoring = UserDefaultsLaunchTargetStore(),
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        cliRunner: CLIRunning = ProcessCLIRunner(),
        homeDirectory: String = NSHomeDirectory(),
        t3Secrets: SecretStoring = KeychainSecretStore(),
        t3Meta: T3MetaStoring = UserDefaultsT3Meta(),
        t3Server: T3Serving = T3HTTPServer(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isProcessAlive: @escaping @Sendable (Int) -> Bool = { pid in kill(pid_t(pid), 0) == 0 || errno == EPERM },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.launcher = launcher
        self.resolvePath = resolvePath
        self.pasteboard = pasteboard
        self.fileManager = fileManager
        self.opener = opener
        self.launchTargetStore = launchTargetStore
        self.sleep = sleep
        self.cliRunner = cliRunner
        self.homeDirectory = homeDirectory
        self.t3Secrets = t3Secrets
        self.t3Meta = t3Meta
        self.t3Server = t3Server
        self.environment = environment
        self.isProcessAlive = isProcessAlive
        self.clock = clock
        let saved = launchTargetStore.load() ?? .claudeTerminal
        self.defaultTarget = saved
        self.launchTarget = saved
    }

    /// Checks the CLIs on the login-shell PATH and the apps on this Mac, then falls back off a
    /// pick (saved or default) that is not available. `folder` is the one the Superset check uses.
    func loadAvailability(folder: URL) async {
        let resolution = await resolvePath()
        availability = LaunchAvailability.detect(
            searchPath: resolution.path, opener: opener, fileManager: fileManager, homeDirectory: homeDirectory)
        await refreshT3Availability()
        await refreshSupersetAvailability(folder: folder)
    }

    /// WAG-264: T3 Code rows. Reads the app, the saved token and its end date, and the server file.
    /// One `t3 auth session issue --help` tells whether the command can limit a token. No network call is made.
    /// Called on open and when the menu opens.
    func refreshT3Availability() async {
        let path = await resolvePath().path
        var scoped: Bool?
        if let cli = T3Command.findCLI(searchPath: path, homeDirectory: homeDirectory, fileManager: fileManager) {
            scoped = await T3Command.probeScope(runner: cliRunner, cli: cli, searchPath: path)
        }
        availability.t3 = T3Readiness.status(
            appInstalled: opener.isAppInstalled(bundleIdentifier: T3Runtime.bundleID),
            scopeSupported: scoped,
            tokenPresent: t3Secrets.load() != nil, expiry: t3Meta.expiry,
            server: T3Runtime.serverStatus(homeDirectory: homeDirectory, environment: environment, isProcessAlive: isProcessAlive),
            now: clock())
        fallBackIfUnavailable()
    }

    /// Asks the Superset CLI (one `projects list`, about 2 s at most, off the main thread) whether
    /// it is signed in, running and has a project for the folder. Called on open, on a folder
    /// change and when the menu opens. Never signs in, starts the service or adds a project.
    func refreshSupersetAvailability(folder: URL) async {
        supersetCheckID += 1
        let id = supersetCheckID
        let resolution = await resolvePath()
        let checked = await SupersetCommand.check(
            folder: folder.path, searchPath: resolution.path, homeDirectory: homeDirectory,
            runner: cliRunner)
        guard id == supersetCheckID else { return }
        availability.superset = checked.status
        fallBackIfUnavailable()
    }

    /// A pick (saved or default) that is not available falls back to the first target that is.
    private func fallBackIfUnavailable() {
        guard let fallback = LaunchTarget.allCases.first(where: availability.isAvailable) else { return }
        // The saved default stays on disk; only this session of the app uses the fallback.
        if !availability.isAvailable(defaultTarget) { defaultTarget = fallback }
        if !availability.isAvailable(launchTarget) { launchTarget = defaultTarget }
    }

    /// The chip's menu picks a target for this run only. The saved default does not change.
    func chooseLaunchTarget(_ target: LaunchTarget) {
        guard availability.isAvailable(target) else { return }
        UsageReporter.current?.record(.launchTargetChosen, variantName: target.rawValue)
        launchTarget = target
    }

    /// "Use as my default": saves this run's pick.
    func useCurrentAsDefault() {
        guard availability.isAvailable(launchTarget) else { return }
        defaultTarget = launchTarget
        launchTargetStore.save(launchTarget)
    }

    /// After a start, the next idea begins from the default again.
    func resetToDefault() { launchTarget = defaultTarget }

    /// True when this run uses another target than the default.
    var differsFromDefault: Bool { launchTarget != defaultTarget }

    /// Starts a new session with the current target. Returns whether the prompt left; `errorText`
    /// holds the reason, or a notice when it left by another way (the Claude-app length fallback).
    func start(prompt text: String, folder: URL, topic: String) async -> Bool {
        errorText = nil
        switch launchTarget {
        case .claudeTerminal:
            return await launchInTerminal(binaryName: "claude", agentName: "Claude Code", prompt: text, folder: folder)
        case .codexTerminal:
            return await launchInTerminal(binaryName: "codex", agentName: "Codex", prompt: text, folder: folder)
        case .claudeApp:
            guard ClaudeAppURL.fits(prompt: text) else {
                if await launchInTerminal(binaryName: "claude", agentName: "Claude Code", prompt: text, folder: folder) {
                    errorText = "The prompt was too long for the Claude app. Opened Terminal with Claude Code instead."
                }
                return false
            }
            guard let url = ClaudeAppURL.build(prompt: text, folder: folder.path), opener.open(url: url) else {
                errorText = "Waggle could not open the Claude app. Copy the prompt instead."
                return false
            }
            return true
        case .codexApp:
            guard let url = CodexAppURL.build(prompt: text, folder: folder.path) else {
                errorText = "Waggle could not open the Codex app. Copy the prompt instead."
                return false
            }
            // WAG-254: openai/codex#30720 drops the prompt when the app was not already
            // running, so the prompt always lands on the clipboard too, and a cold app gets a
            // bounded head start before the link is opened.
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            if let appURL = opener.appURL(toOpen: URL(string: "codex://")!), !opener.isRunning(appURL: appURL) {
                opener.launchApp(at: appURL)
                await Self.waitUntilRunning(appURL: appURL, opener: opener, sleep: sleep)
            }
            guard opener.open(url: url) else {
                errorText = "Waggle could not open the Codex app. The prompt is on your clipboard."
                return false
            }
            return true
        case .claudeSuperset, .codexSuperset:
            let resolution = await resolvePath()
            let launcher = SupersetLauncher(runner: cliRunner, homeDirectory: homeDirectory)
            switch await launcher.launch(target: launchTarget, folder: folder.path, topic: topic, prompt: text, searchPath: resolution.path) {
            case .started: return true
            case .failed(let message):
                errorText = message
                return false
            }
        case .claudeT3, .codexT3:
            let resolution = await resolvePath()
            let launcher = T3Launcher(
                secrets: t3Secrets, meta: t3Meta, server: t3Server, runner: cliRunner, homeDirectory: homeDirectory,
                environment: environment, now: clock, isProcessAlive: isProcessAlive)
            switch await launcher.launch(target: launchTarget, folder: folder.path, topic: topic, prompt: text, searchPath: resolution.path) {
            case .started: return true
            case .failed(let message, let copyPrompt):
                if copyPrompt {
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                }
                errorText = message
                return false
            }
        case .conductor:
            guard let url = ConductorURL.build(prompt: text, folder: folder.path) else {
                errorText = "Waggle could not open Conductor. Copy the prompt instead."
                return false
            }
            // Conductor only fills the prompt in, so it also lands on the clipboard.
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            guard opener.open(url: url) else {
                errorText = "Waggle could not open Conductor. The prompt is on your clipboard."
                return false
            }
            return true
        }
    }

    /// Writes the .command file and opens it in Terminal. Returns whether it launched; the
    /// caller decides whether that counts as finishing (it does not, on the Claude-app
    /// length-fallback path, so the notice stays visible).
    private func launchInTerminal(binaryName: String, agentName: String, prompt text: String, folder: URL) async -> Bool {
        let resolution = await resolvePath()
        guard let binaryPath = NewSessionCommand.findExecutable(named: binaryName, searchPath: resolution.path, fileManager: fileManager) else {
            errorText = "Waggle could not find \(agentName) on this Mac. Copy the prompt and paste it where you work."
            return false
        }
        let script = binaryName == "claude"
            ? NewSessionCommand.script(folder: folder.path, prompt: text, claudePath: binaryPath, searchPath: resolution.path)
            : NewSessionCommand.codexScript(folder: folder.path, prompt: text, codexPath: binaryPath, searchPath: resolution.path)
        do {
            try launcher.launch(script: script)
            return true
        } catch {
            errorText = "Waggle could not open Terminal. Copy the prompt instead."
            return false
        }
    }

    /// Polls `isRunning` until it is true or `maxWaitSeconds` pass (about 5 s), with `launchApp`
    /// already called by the caller. Bounds the Codex-app-cold-start workaround above.
    static func waitUntilRunning(
        appURL: URL, opener: ExternalAppOpening, sleep: @Sendable (TimeInterval) async -> Void,
        maxWaitSeconds: Double = 5, pollInterval: Double = 0.25
    ) async {
        var waited = 0.0
        while !opener.isRunning(appURL: appURL) && waited < maxWaitSeconds {
            await sleep(pollInterval)
            waited += pollInterval
        }
    }

}

/// The real Terminal launcher: writes the script to a private temp file and opens it with
/// Terminal. Only the Start button reaches it, and no test does.
struct TerminalAppLauncher: TerminalLaunching {
    struct Failure: Error {}

    func launch(script: String) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("knock-start-\(UUID().uuidString).command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw Failure()
        }
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}
