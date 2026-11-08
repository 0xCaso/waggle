import AppKit
import UniformTypeIdentifiers
import Foundation

/// HAIL-169: "Start from a document". What the person wants to do with a PRD or a brief.
enum DocumentGoal: String, CaseIterable, Identifiable, Sendable {
    /// WAG-255: plan the idea with the operator in one Waggle plan ask.
    case plan
    case decisions
    case pen
    case prototype
    case review

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plan: return "Plan it with me"
        case .decisions: return "Options to decide on"
        case .pen: return "Screens to look at"
        case .prototype: return "A clickable prototype"
        case .review: return "A review of the doc"
        }
    }

    /// WAG-255: the short names on the New idea page's goal chips.
    var chipTitle: String {
        switch self {
        case .plan: return "Plan it with me"
        case .decisions: return "Options to decide on"
        case .pen: return "Screens to look at"
        case .prototype: return "Clickable prototype"
        case .review: return "Review"
        }
    }

    /// The goals the New idea page offers, in order. "Screens to look at" stays in the document sheet.
    static let ideaGoals: [DocumentGoal] = [.plan, .decisions, .prototype, .review]

    var detail: String {
        switch self {
        case .plan: return "Ask me questions, show approaches, then write the plan, in one Waggle decision."
        case .decisions: return "Read it, find the open decisions, ask me in Waggle with options."
        case .pen: return "Draw the key screens with any tool it has, or as images, and send them for review."
        case .prototype: return "Build the main flow as a prototype I can try in Waggle."
        case .review: return "Tell me what is unclear or missing, one point at a time."
        }
    }
}

/// Builds the one prompt the sheet previews, copies and sends. Knock only passes the file path:
/// it never reads or changes the document.
enum DocumentPrompt {
    /// WAG-255: the prompt for an idea written on the New idea page: the idea text, the paths of the
    /// attached files (none is fine), then what the agent does. Waggle only passes paths.
    static func build(idea: String, paths: [String], goal: DocumentGoal) -> String {
        var parts: [String] = []
        let text = idea.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { parts.append("My idea:\n\(text)") }
        if !paths.isEmpty {
            parts.append("Attached files:\n" + paths.map { "- \(displayPath($0))" }.joined(separator: "\n"))
        }
        let read = paths.isEmpty ? "Read the idea." : "Read the idea and the attached files."
        parts.append("\(read) \(instruction(for: goal))")
        return parts.joined(separator: "\n\n")
    }

    /// What the agent does for a goal. Written in ASD-STE100.
    static func instruction(for goal: DocumentGoal) -> String {
        switch goal {
        case .plan:
            return "Plan it with me in ONE Waggle plan ask. Call waggle_ask with kind \"plan\". Go through the stages in this order: questions, approaches, design, spec. Use waggle_update for each later round. At the spec stage, write the PRD as a markdown file in the session folder and attach it to the ask."
        case .decisions:
            return "Find the open decisions in it and ask me in Waggle, one at a time, with options and your recommendation."
        case .pen:
            // No tool is named: the agent uses a design tool it has, or sends images. The design kit
            // (project file or the default from Settings) reaches it through Knock's guide; the app
            // never looks inside the project folder for it.
            return "Draw the key screens with a design tool you have (Pen, Figma, ...), or as images, and send them to me in Waggle for review. Use the design kit from Waggle's guide if there is one."
        case .prototype:
            return "Build the main flow as a clickable prototype and send it to me in Waggle to try."
        case .review:
            return "Tell me what is unclear or missing in it, one point at a time, as asks in Waggle."
        }
    }

    /// A path with spaces or quotes is wrapped in double quotes, so the agent reads one path.
    static func displayPath(_ path: String) -> String {
        let special = path.contains { $0.isWhitespace || $0 == "\"" || $0 == "'" }
        return special ? "\"\(path)\"" : path
    }

    /// One line, and no double quote that would end the topic early.
    static func cleaned(_ topic: String) -> String {
        topic.replacingOccurrences(of: "\"", with: "'")
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

}

/// How "Start session" runs `claude` or `codex` in Terminal. Quoting lives here so it is testable.
enum NewSessionCommand {
    /// One POSIX shell word: single quotes, with each inner single quote closed, escaped and reopened.
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The .command file: it deletes itself, goes to the folder, and starts `claude` with the
    /// prompt as its first message. Every value is quoted, so a file name, a topic or a path
    /// cannot add a command.
    static func script(folder: String, prompt: String, claudePath: String, searchPath: String) -> String {
        commandFile(folder: folder, prompt: prompt, binaryPath: claudePath, searchPath: searchPath)
    }

    /// WAG-254: Codex's own version of the same .command file, running `codex` instead of `claude`.
    static func codexScript(folder: String, prompt: String, codexPath: String, searchPath: String) -> String {
        commandFile(folder: folder, prompt: prompt, binaryPath: codexPath, searchPath: searchPath)
    }

    private static func commandFile(folder: String, prompt: String, binaryPath: String, searchPath: String) -> String {
        [
            "#!/bin/zsh",
            "rm -f -- \"$0\"",
            "cd -- \(shellQuote(folder)) || exit 1",
            "export PATH=\(shellQuote(searchPath))",
            "exec \(shellQuote(binaryPath)) \(shellQuote(prompt))",
            "",
        ].joined(separator: "\n")
    }

    /// The first `claude` that is executable on `searchPath`, or nil.
    static func findClaude(searchPath: String, fileManager: FileManager = .default) -> String? {
        findExecutable(named: "claude", searchPath: searchPath, fileManager: fileManager)
    }

    /// The first `codex` that is executable on `searchPath`, or nil (WAG-254, same lookup as `findClaude`).
    static func findCodex(searchPath: String, fileManager: FileManager = .default) -> String? {
        findExecutable(named: "codex", searchPath: searchPath, fileManager: fileManager)
    }

    /// The first `name` that is executable on `searchPath`, or nil.
    static func findExecutable(named name: String, searchPath: String, fileManager: FileManager = .default) -> String? {
        for directory in searchPath.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

/// Opens Terminal on a script. A fake stands in for it in every test: a test never opens Terminal.
protocol TerminalLaunching: Sendable {
    func launch(script: String) throws
}

// MARK: - WAG-254: pick the agent and where it opens

/// The places "Start a new session" can send the prompt. One case per launch target, each
/// with its own pure builder (`NewSessionCommand.script`/`codexScript`, `ClaudeAppURL`,
/// `CodexAppURL`, `SupersetCommand`, `ConductorURL`). The menu lists them in declaration order.
enum LaunchTarget: String, CaseIterable, Identifiable, Sendable {
    case claudeTerminal
    case codexTerminal
    case claudeApp
    case codexApp
    case claudeSuperset
    case codexSuperset
    case conductor
    case claudeT3
    case codexT3

    var id: String { rawValue }

    /// The menu item's first line: "Claude Code" or "Codex".
    var agentName: String {
        switch self {
        case .claudeTerminal, .claudeApp, .claudeSuperset, .claudeT3: return "Claude Code"
        case .codexTerminal, .codexApp, .codexSuperset, .codexT3: return "Codex"
        case .conductor: return "In Conductor"
        }
    }

    /// The chip's words: "Claude Code · Claude app".
    var chipLabel: String {
        switch self {
        case .claudeTerminal: return "Claude Code · Terminal"
        case .codexTerminal: return "Codex · Terminal"
        case .claudeApp: return "Claude Code · Claude app"
        case .codexApp: return "Codex · Codex app"
        case .claudeSuperset: return "Claude Code · Superset"
        case .codexSuperset: return "Codex · Superset"
        case .claudeT3: return "Claude Code · T3 Code"
        case .codexT3: return "Codex · T3 Code"
        case .conductor: return "Conductor"
        }
    }

    /// The menu item's second line, when the target is on this Mac: "in Terminal", "in the
    /// Claude app" or "in the Codex app".
    var whereLabel: String {
        switch self {
        case .claudeTerminal, .codexTerminal: return "in Terminal"
        case .claudeApp: return "in the Claude app"
        case .codexApp: return "in the Codex app"
        case .claudeSuperset, .codexSuperset: return "in Superset"
        case .claudeT3, .codexT3: return "in T3 Code"
        case .conductor: return "Prompt filled in, you press Enter"
        }
    }

    /// The split button's main label for this pick.
    var mainLabel: String {
        switch self {
        case .claudeTerminal, .codexTerminal: return "Start in Terminal"
        case .claudeApp: return "Start in the Claude app"
        case .codexApp: return "Start in the Codex app"
        case .claudeSuperset, .codexSuperset: return "Start in Superset"
        case .claudeT3, .codexT3: return "Start in T3 Code"
        case .conductor: return "Start in Conductor"
        }
    }

    /// The "Start a new session" row's second line for this pick.
    func metaLine(folder: String) -> String {
        switch self {
        case .claudeTerminal: return "Opens Terminal in \(folder) and starts Claude Code."
        case .codexTerminal: return "Opens Terminal in \(folder) and starts Codex."
        case .claudeApp: return "Opens the Claude app in \(folder) with your prompt typed."
        case .codexApp: return "Opens the Codex app in \(folder) with your prompt typed."
        case .claudeSuperset: return "Makes a Superset workspace for \(folder) and starts Claude Code."
        case .codexSuperset: return "Makes a Superset workspace for \(folder) and starts Codex."
        case .conductor: return "Opens Conductor in \(folder) with your prompt filled in. You press Enter."
        case .claudeT3: return "Starts a T3 Code thread for \(folder) with Claude Code and sends your prompt."
        case .codexT3: return "Starts a T3 Code thread for \(folder) with Codex and sends your prompt."
        }
    }
}

/// Why a Superset or Conductor row is greyed in the menu. `text` is the plain line shown.
enum LaunchBlock: Equatable, Sendable {
    case notOnMac
    case signIn
    case addFolder
    case startService
    case connectT3
    case openT3

    var text: String {
        switch self {
        case .notOnMac: return "Not on this Mac"
        case .signIn: return "Sign in to Superset first"
        case .addFolder: return "Add this folder in Superset first"
        case .startService: return "Start Superset first"
        case .connectT3: return "Connect T3 Code in Settings"
        case .openT3: return "Open T3 Code first"
        }
    }
}

/// Whether each launch target is on this Mac: the CLI on the login-shell PATH, or the app
/// installed / registered for its URL scheme. Superset also needs a login, a running service
/// and a project for the folder, so it carries a reason (WAG-263).
struct LaunchAvailability: Equatable, Sendable {
    var claudeTerminal: Bool
    var codexTerminal: Bool
    var claudeApp: Bool
    var codexApp: Bool
    var superset: SupersetStatus = .ready
    var conductor: Bool = true
    /// WAG-264: T3 Code reuses the Superset status shape: ready, or blocked with a reason.
    var t3: SupersetStatus = .ready

    static let allAvailable = LaunchAvailability(claudeTerminal: true, codexTerminal: true, claudeApp: true, codexApp: true)

    func isAvailable(_ target: LaunchTarget) -> Bool {
        switch target {
        case .claudeTerminal: return claudeTerminal
        case .codexTerminal: return codexTerminal
        case .claudeApp: return claudeApp
        case .codexApp: return codexApp
        case .claudeSuperset, .codexSuperset: return superset == .ready
        case .conductor: return conductor
        case .claudeT3, .codexT3: return t3 == .ready
        }
    }

    /// The greyed second line for a target that cannot work, or nil when it can.
    func unavailableText(_ target: LaunchTarget) -> String? {
        if isAvailable(target) { return nil }
        if case .blocked(let block) = superset, target == .claudeSuperset || target == .codexSuperset { return block.text }
        if case .blocked(let block) = t3, target == .claudeT3 || target == .codexT3 { return block.text }
        return LaunchBlock.notOnMac.text
    }

    /// `com.anthropic.claudefordesktop`: confirmed in the installed app (Claude 2.19675.1).
    static let claudeAppBundleID = "com.anthropic.claudefordesktop"

    /// The quick checks only (no CLI run). Superset is `.blocked(.notOnMac)` when its CLI is
    /// missing, else `.ready` until `SupersetCommand.check` has run.
    static func detect(
        searchPath: String, opener: ExternalAppOpening, fileManager: FileManager = .default,
        homeDirectory: String = NSHomeDirectory()
    ) -> LaunchAvailability {
        LaunchAvailability(
            claudeTerminal: NewSessionCommand.findClaude(searchPath: searchPath, fileManager: fileManager) != nil,
            codexTerminal: NewSessionCommand.findCodex(searchPath: searchPath, fileManager: fileManager) != nil,
            claudeApp: opener.isAppInstalled(bundleIdentifier: claudeAppBundleID),
            codexApp: opener.appURL(toOpen: URL(string: "codex://")!) != nil,
            superset: SupersetCommand.findCLI(searchPath: searchPath, homeDirectory: homeDirectory, fileManager: fileManager) == nil
                ? .blocked(.notOnMac) : .ready,
            conductor: opener.appURL(toOpen: ConductorURL.schemeProbe) != nil,
            t3: opener.isAppInstalled(bundleIdentifier: T3Runtime.bundleID) ? .ready : .blocked(.notOnMac))
    }
}

/// `claude://code/new?q=<prompt>&folder=<absolute folder>`. The app caps `q` at 14336 characters.
enum ClaudeAppURL {
    static let maxPromptLength = 14336

    static func fits(prompt: String) -> Bool { prompt.count <= maxPromptLength }

    static func build(prompt: String, folder: String) -> URL? {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/new"
        components.queryItems = [
            URLQueryItem(name: "q", value: prompt),
            URLQueryItem(name: "folder", value: folder),
        ]
        return components.url
    }
}

/// `codex://threads/new?prompt=<prompt>&path=<absolute folder>` (developers.openai.com/codex/app/commands).
enum CodexAppURL {
    static func build(prompt: String, folder: String) -> URL? {
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/new"
        components.queryItems = [
            URLQueryItem(name: "prompt", value: prompt),
            URLQueryItem(name: "path", value: folder),
        ]
        return components.url
    }
}

/// Finds and opens the Claude and Codex apps. A fake stands in for it in every test: no test
/// opens a real app or a real URL (WAG-254).
protocol ExternalAppOpening: Sendable {
    func isAppInstalled(bundleIdentifier: String) -> Bool
    /// The app that would open this URL's scheme, if one is registered.
    func appURL(toOpen url: URL) -> URL?
    func isRunning(appURL: URL) -> Bool
    func launchApp(at appURL: URL)
    /// Opens a URL (a `claude://` or `codex://` link). Returns whether something handled it.
    func open(url: URL) -> Bool
}

/// The real opener. Only the sheet's button reaches it, and no test does.
struct WorkspaceAppOpener: ExternalAppOpening {
    func isAppInstalled(bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    func appURL(toOpen url: URL) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: url)
    }

    func isRunning(appURL: URL) -> Bool {
        guard let id = Bundle(url: appURL)?.bundleIdentifier else { return false }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == id }
    }

    func launchApp(at appURL: URL) {
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    func open(url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

/// Saves and loads the launch target pick, one `UserDefaults` key (WAG-254).
protocol LaunchTargetStoring: Sendable {
    func load() -> LaunchTarget?
    func save(_ target: LaunchTarget)
}

struct UserDefaultsLaunchTargetStore: LaunchTargetStoring, @unchecked Sendable {
    static let key = "StartFromDocumentLaunchTarget"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> LaunchTarget? {
        defaults.string(forKey: Self.key).flatMap(LaunchTarget.init(rawValue:))
    }

    func save(_ target: LaunchTarget) {
        defaults.set(target.rawValue, forKey: Self.key)
    }
}
