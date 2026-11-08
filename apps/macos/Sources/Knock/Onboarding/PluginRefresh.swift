import Foundation

/// HAIL-135: after a Sparkle update the app's bundled Claude Code plugin can be newer than
/// the installed one. At launch the app runs `knock install claude --refresh`, which updates
/// a plugin that is installed already and does nothing otherwise, so it never installs for a
/// user who removed the plugin. Tests, evidence runs (a set KNOCK_HOME) and dev builds skip
/// it: they must not touch a real Claude Code.
enum PluginRefresh {
    static func shouldRun(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        hasBundledPlugin: Bool = Bundle.main.url(forResource: "claude-plugin", withExtension: nil) != nil
    ) -> Bool {
        guard hasBundledPlugin else { return false }
        if let home = environment["KNOCK_HOME"], !home.isEmpty { return false }
        if environment["XCTestConfigurationFilePath"] != nil { return false }
        if let id = bundleIdentifier, id.hasSuffix(".dev") { return false }
        return true
    }

    static let arguments = ["install", "claude", "--refresh"]
    /// HAIL-137: the same for the Codex plugin. Codex gets it only when it is installed already.
    static let codexArguments = ["install", "codex", "--refresh"]

    static let claudeFailureMessage = "Waggle could not update its Claude Code plugin. Run waggle install claude --refresh in a terminal."
    static let codexFailureMessage = "Waggle could not update its Codex plugin. Run waggle install codex --refresh in a terminal."

    /// HAIL-176: the same two runs also move an installed `knock@knock` plugin (or the old Codex
    /// entry) to `waggle@waggle`: the binary does that inside `--refresh`, so the old plugin is
    /// handled on every launch, whether or not the versions differ. It is safe to run again.
    /// Each run is logged. A failure goes to `LaunchMigrationStatus` (shown in Settings > Agents)
    /// and never stops the app.
    static func runAtLaunch(runner: OnboardingCommandRunning = ProcessCommandRunner()) {
        guard shouldRun() else { return }
        Task.detached(priority: .utility) {
            await refreshBoth(runner: runner)
        }
    }

    /// The body of `runAtLaunch`, apart from the gate and the detached task so a test can await it.
    static func refreshBoth(
        runner: OnboardingCommandRunning,
        status: LaunchMigrationStatus? = nil,
        log: @escaping @Sendable (String) -> Void = { LaunchMigrationLog.append($0) }
    ) async {
        let claude = await runLogged(runner, arguments, label: "claude", log: log)
        let codex = await runLogged(runner, codexArguments, label: "codex", log: log)
        await MainActor.run {
            let target = status ?? LaunchMigrationStatus.shared
            target.pluginFailure = claude != 0 ? claudeFailureMessage : (codex != 0 ? codexFailureMessage : nil)
        }
    }

    private static func runLogged(
        _ runner: OnboardingCommandRunning, _ args: [String], label: String,
        log: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        let code = await runner.run(args, onLine: { line in log("pluginRefresh \(label) | \(line)") })
        log("pluginRefresh \(label) exit=\(code)")
        return code
    }
}
