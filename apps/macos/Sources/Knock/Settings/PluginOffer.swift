import Foundation

/// HAIL-136: how Claude Code reaches Knock, read from one `knock doctor` run, and the rules
/// for the one-time plugin offer. Pure, so the visibility rules are testable without a UI.
struct ClaudePluginStatus: Equatable {
    enum Mode: Equatable {
        /// Claude Code is not set up for Knock (or not installed).
        case notConnected
        /// The old user-level MCP entry serves Knock.
        case mcpEntry
        /// The plugin serves Knock (an older entry beside it counts as plugin mode too).
        case plugin
    }

    var mode: Mode = .notConnected
    /// Claude Code has `claude plugin` and this app bundles the plugin.
    var pluginCapable = false

    init(mode: Mode = .notConnected, pluginCapable: Bool = false) {
        self.mode = mode
        self.pluginCapable = pluginCapable
    }

    init(checks: [DoctorCheckResult]) {
        let name = Runtime.claude.displayName
        func ok(_ label: String) -> Bool { checks.contains { $0.label == label && $0.status == .ok } }
        if ok("\(name) installed as plugin") {
            mode = .plugin
        } else if ok("\(name) installed as MCP entry") {
            mode = .mcpEntry
        } else {
            mode = .notConnected
        }
        pluginCapable = ok("\(name) can install the Waggle plugin")
    }

    /// The offer applies to an existing user on the old entry whose Claude Code can take the plugin.
    var offerApplies: Bool { mode == .mcpEntry && pluginCapable }

    /// The Home card: the offer, until "Not now" hides it for good.
    func showsHomeCard(dismissed: Bool) -> Bool { offerApplies && !dismissed }

    /// The Settings row stays after "Not now".
    var showsSettingsOffer: Bool { offerApplies }

    /// The On/Off control needs a connected Claude Code that can take the plugin (or has it).
    var showsToggle: Bool { mode == .plugin || offerApplies }

    var isPluginOn: Bool { mode == .plugin }
}

/// The two `knock` commands behind the plugin offer and the On/Off control.
enum PluginCommand {
    /// Plugin mode: installs the bundled plugin and removes the old entry.
    static let on = ["install", "claude"]
    /// MCP entry only: removes the plugin and its marketplace.
    static let off = ["install", "claude", "--mcp"]

    static func arguments(turningOn: Bool) -> [String] { turningOn ? on : off }
}

/// "Not now" for the Home card, kept in `UserDefaults` like the other app preferences
/// (a test or evidence copy's own bundle id isolates it).
enum PluginOfferSettings {
    private static let key = "pluginOfferDismissed"

    static func isDismissed(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func setDismissed(_ dismissed: Bool, defaults: UserDefaults = .standard) {
        defaults.set(dismissed, forKey: key)
    }
}

/// Shared by the Home card and the Settings › Agents rows, so one install clears both.
@MainActor
final class PluginOfferModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working(turningOn: Bool)
        case failed(String)
        case done(String)
    }

    static let shared = PluginOfferModel()

    @Published private(set) var status = ClaudePluginStatus()
    /// The last doctor lines, so the Agents rows can follow a toggle without a second run.
    @Published private(set) var checks: [DoctorCheckResult] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var dismissed: Bool
    /// HAIL-138: the checklist after a successful install, until Done or Skip.
    @Published private(set) var setup: PluginSetup?

    private let runner: OnboardingCommandRunning
    private let defaults: UserDefaults
    private let clock: () -> Date
    private var started = false

    init(
        runner: OnboardingCommandRunning = ProcessCommandRunner(), defaults: UserDefaults = .standard,
        clock: @escaping () -> Date = Date.init
    ) {
        self.runner = runner
        self.defaults = defaults
        self.clock = clock
        self.dismissed = PluginOfferSettings.isDismissed(defaults: defaults)
        self.setup = PluginSetupSettings.load(defaults: defaults)
    }

    /// The setup card shows from the install until Done or Skip. An MCP-entry mode means the plugin is off.
    var showsSetupCard: Bool { (setup?.isActive ?? false) && status.mode != .mcpEntry }

    /// Feeds the checklist what the daemon shows now (sessions and open asks).
    func observe(sessions: [SessionInfo], cases: [Case]) {
        guard var current = setup, current.isActive else { return }
        if current.observe(sessions: sessions, cases: cases, now: clock()) { storeSetup(current) }
    }

    /// Done and Skip: the card is gone for good.
    func finishSetup() {
        guard var current = setup else { return }
        current.finished = true
        storeSetup(current)
    }

    private func storeSetup(_ value: PluginSetup?) {
        setup = value
        PluginSetupSettings.save(value, defaults: defaults)
    }

    var showsHomeCard: Bool { status.showsHomeCard(dismissed: dismissed) }

    var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    /// Probes once per app run for the Home card; later changes arrive from Settings.
    func startIfNeeded() async {
        guard !started else { return }
        started = true
        await refresh()
        await runEvidenceActionIfRequested()
    }

    /// Evidence only: `KNOCK_EVIDENCE_PLUGIN_ACTION=on|off,<delay s>` turns the plugin on or
    /// off after the delay, as a click on the Install button or the switch would.
    private func runEvidenceActionIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) async {
        if let raw = environment["KNOCK_EVIDENCE_PLUGIN_SETUP"] { seedEvidenceSetup(raw) }
        guard let raw = environment["KNOCK_EVIDENCE_PLUGIN_ACTION"] else { return }
        let parts = raw.split(separator: ",").map(String.init)
        guard let action = parts.first, action == "on" || action == "off" else { return }
        let delay = parts.dropFirst().first.flatMap(Double.init) ?? 0
        try? await Task.sleep(for: .seconds(delay))
        await setPlugin(on: action == "on")
    }

    /// Evidence only: `KNOCK_EVIDENCE_PLUGIN_SETUP=waiting|seen|working[,noold]` shows the checklist
    /// in that step, in memory only, with a fake session name.
    private func seedEvidenceSetup(_ raw: String) {
        let parts = raw.split(separator: ",").map(String.init)
        guard let step = parts.first else { return }
        var seeded = PluginSetup(installedAt: clock(), hadOldConnection: !parts.contains("noold"))
        if step == "seen" || step == "working" {
            seeded.seenName = "Fix the login redirect"
            seeded.seenTaskId = "evidence"
            seeded.seenAt = clock()
        }
        if step == "working" { seeded.testAskAt = clock() }
        setup = seeded
        // The plugin is on, so the Settings switch and the compact checklist show too.
        apply(checks: ["ok    Claude Code installed as plugin", "ok    Claude Code can install the Waggle plugin"]
            .compactMap(DoctorLineParser.parse))
    }

    /// Takes the status from a doctor run another model already did.
    func apply(checks: [DoctorCheckResult]) {
        self.checks = checks
        status = ClaudePluginStatus(checks: checks)
    }

    func refresh() async {
        var checks: [DoctorCheckResult] = []
        _ = await runner.run(["doctor"], onLine: { line in
            if let check = DoctorLineParser.parse(line) { checks.append(check) }
        })
        apply(checks: checks)
    }

    /// "Not now": hides the Home card for good.
    func dismiss() {
        dismissed = true
        PluginOfferSettings.setDismissed(true, defaults: defaults)
    }

    /// "Install plugin" and the On/Off control: run the command, check the result.
    func setPlugin(on turningOn: Bool) async {
        guard !isWorking else { return }
        let hadOldConnection = status.mode == .mcpEntry
        phase = .working(turningOn: turningOn)
        let code = await runner.run(PluginCommand.arguments(turningOn: turningOn), onLine: { _ in })
        await refresh()
        let reached = turningOn ? status.mode == .plugin : status.mode == .mcpEntry
        if code == 0, reached {
            // Turning on starts a fresh checklist; turning off drops it.
            storeSetup(turningOn ? PluginSetup(installedAt: clock(), hadOldConnection: hadOldConnection) : nil)
            phase = .done(turningOn
                ? "The plugin is on. New Claude Code sessions use it."
                : "The plugin is off. Waggle connects through the MCP entry.")
        } else {
            phase = .failed(turningOn
                ? "Could not turn the plugin on. Waggle still connects through the MCP entry."
                : "Could not turn the plugin off. Try again, or run waggle install claude --mcp.")
        }
    }
}
