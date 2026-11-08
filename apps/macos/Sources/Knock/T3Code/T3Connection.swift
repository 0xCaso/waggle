import Foundation

// WAG-264: connect T3 Code once from Settings. Waggle asks the `t3` command for a token, keeps it
// in the Keychain, and remembers when it ends.

/// What the Settings "T3 Code" card shows.
enum T3CardState: Equatable, Sendable {
    case notOnMac
    case installCLI
    /// The `t3` command cannot limit a token to a scope. Waggle never keeps a full-access token.
    case scopeUnsupported
    case notConnected
    case connected(daysLeft: Int)
    case expired

    /// - Parameters:
    ///   - hasToken: a token is in the Keychain.
    ///   - expiry: when that token ends, nil when unknown (counts as expired).
    ///   - scopeSupported: the installed `t3 auth session issue` lists `--scope`. Ignored when `cliFound` is false.
    static func resolve(
        appInstalled: Bool, cliFound: Bool, scopeSupported: Bool, hasToken: Bool, expiry: Date?, now: Date
    ) -> T3CardState {
        guard appInstalled else { return .notOnMac }
        if cliFound, !scopeSupported { return .scopeUnsupported }
        if hasToken {
            guard let expiry, expiry > now else { return cliFound ? .expired : .installCLI }
            return .connected(daysLeft: daysLeft(until: expiry, now: now))
        }
        return cliFound ? .notConnected : .installCLI
    }

    /// Whole days, rounded up, so the last day reads "1 day" and never "0 days".
    static func daysLeft(until expiry: Date, now: Date) -> Int {
        max(1, Int((expiry.timeIntervalSince(now) / 86_400).rounded(.up)))
    }

    /// The one plain line under the card title.
    var help: String {
        switch self {
        case .notOnMac: return "Install T3 Code to start threads in it from Waggle."
        case .installCLI: return "Waggle needs the t3 command to connect. Run the line below in Terminal, then come back."
        case .scopeUnsupported: return "Your T3 Code version cannot limit access yet. Waggle opens T3 and copies the prompt until you update."
        case .notConnected: return "Connect once and \"Start a new session\" can open a thread in T3 Code."
        case .connected: return "Waggle can start threads in T3 Code. The token stays in the Keychain on this Mac."
        case .expired: return "The connection ended. Renew it to start threads in T3 Code again."
        }
    }

    var title: String {
        switch self {
        case .notOnMac: return "Not on this Mac"
        case .installCLI: return "Install the t3 command"
        case .scopeUnsupported: return "Update T3 Code"
        case .notConnected: return "Not connected"
        case .connected(let days): return "Connected · renews in \(days) \(days == 1 ? "day" : "days")"
        case .expired: return "Expired"
        }
    }
}

/// The `t3` command lines Waggle runs. Every argument goes in an argument list, never a shell string.
enum T3Command {
    /// T3's own install line (README, "Command line").
    static let installLine = "curl -fsSL https://t3.codes/install.sh | sh"
    static let ttl = "30d"
    static let ttlDays = 30
    static let label = "Waggle"
    /// Marks the sessions Waggle made, so Disconnect can find them in `auth session list`.
    static let subject = "waggle"
    static let helpTimeout: TimeInterval = 5
    static let issueTimeout: TimeInterval = 30
    static let revokeTimeout: TimeInterval = 10
    static let appTimeout: TimeInterval = 15

    static let scopes = ["orchestration:read", "orchestration:operate"]

    /// `t3` on the login-shell PATH, else in the folders the install line is known to use.
    static func findCLI(searchPath: String, homeDirectory: String, fileManager: FileManager = .default) -> String? {
        let extended = searchPath + ":" + homeDirectory + "/.local/bin:" + homeDirectory + "/.t3/bin"
        return NewSessionCommand.findExecutable(named: "t3", searchPath: extended, fileManager: fileManager)
    }

    static let issueHelpArguments = ["auth", "session", "issue", "--help"]

    /// 0.0.46-nightly.20261005 has no `--scope` flag: `issue` there always gives the full admin scope set.
    /// Waggle never keeps such a token, so Connect needs a CLI that lists the flag.
    static func supportsScope(helpText: String) -> Bool { helpText.contains("--scope") }

    /// Runs `issue --help`. A command that fails or times out counts as not supporting `--scope`.
    static func probeScope(runner: CLIRunning, cli: String, searchPath: String) async -> Bool {
        let help = await runner.run(executable: cli, arguments: issueHelpArguments, searchPath: searchPath, timeout: helpTimeout)
        return supportsScope(helpText: help.stdout + help.stderr)
    }

    static func issueArguments() -> [String] {
        var arguments = ["auth", "session", "issue"]
        for scope in scopes { arguments += ["--scope", scope] }
        arguments += ["--ttl", ttl, "--label", label, "--subject", subject, "--token-only"]
        return arguments
    }

    /// `--token-only` prints the token alone: one line, no spaces.
    static func token(from stdout: String) -> String? {
        let line = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.contains(where: \.isWhitespace) else { return nil }
        return line
    }

    static let listArguments = ["auth", "session", "list", "--json"]

    static func revokeArguments(sessionID: String) -> [String] { ["auth", "session", "revoke", sessionID] }

    /// The ids of the sessions Waggle made, from `auth session list --json`.
    static func waggleSessionIDs(listJSON: String) -> [String] {
        guard let data = listJSON.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return array.compactMap { item in
            guard (item["subject"] as? String) == subject, let id = item["sessionId"] as? String, !id.isEmpty else { return nil }
            return id
        }
    }

    static func appArguments(folder: String) -> [String] { ["app", folder] }
}

/// The T3 Code card's state and its Connect, Renew and Disconnect actions.
@MainActor
final class T3ConnectionModel: ObservableObject {
    @Published private(set) var state: T3CardState = .notConnected
    @Published private(set) var busy = false
    @Published private(set) var failure: String?
    /// False until the first `refresh()` has answered, so the card does not flash a wrong state.
    @Published private(set) var loaded = false

    private let secrets: SecretStoring
    private let meta: T3MetaStoring
    private let runner: CLIRunning
    private let opener: ExternalAppOpening
    private let resolvePath: @Sendable () async -> LoginShellPathResolution
    private let homeDirectory: String
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    init(
        secrets: SecretStoring = KeychainSecretStore(),
        meta: T3MetaStoring = UserDefaultsT3Meta(),
        runner: CLIRunning = ProcessCLIRunner(),
        opener: ExternalAppOpening = WorkspaceAppOpener(),
        resolvePath: @escaping @Sendable () async -> LoginShellPathResolution = { await LoginShellPath.resolve() },
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.secrets = secrets
        self.meta = meta
        self.runner = runner
        self.opener = opener
        self.resolvePath = resolvePath
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.now = now
    }

    func refresh() async {
        let path = await resolvePath().path
        await apply(searchPath: path)
        loaded = true
    }

    private func apply(searchPath: String, scopeKnown: Bool? = nil) async {
        let cli = T3Command.findCLI(searchPath: searchPath, homeDirectory: homeDirectory, fileManager: fileManager)
        var scoped = true
        if let cli {
            if let scopeKnown { scoped = scopeKnown } else {
                scoped = await T3Command.probeScope(runner: runner, cli: cli, searchPath: searchPath)
            }
        }
        // A token kept from a CLI that cannot limit access is never used. Remove it.
        if cli != nil, !scoped, secrets.load() != nil {
            secrets.delete()
            meta.setExpiry(nil)
            meta.setRemindedFor(nil)
        }
        state = T3CardState.resolve(
            appInstalled: opener.isAppInstalled(bundleIdentifier: T3Runtime.bundleID),
            cliFound: cli != nil, scopeSupported: scoped,
            hasToken: secrets.load() != nil, expiry: meta.expiry, now: now())
    }

    /// "Connect" and "Renew" are the same action: ask for a new token and replace the old one.
    func connect() async {
        guard !busy else { return }
        busy = true
        failure = nil
        defer { busy = false }
        let path = await resolvePath().path
        guard let cli = T3Command.findCLI(searchPath: path, homeDirectory: homeDirectory, fileManager: fileManager) else {
            failure = "Waggle could not find the t3 command. Install it first."
            await apply(searchPath: path)
            return
        }
        guard await T3Command.probeScope(runner: runner, cli: cli, searchPath: path) else {
            await apply(searchPath: path, scopeKnown: false)
            return
        }
        let issued = await runner.run(
            executable: cli, arguments: T3Command.issueArguments(), searchPath: path,
            timeout: T3Command.issueTimeout)
        // Nothing the command printed goes into the message: stdout holds the token.
        guard issued.succeeded, let token = T3Command.token(from: issued.stdout) else {
            failure = issued.timedOut
                ? "The t3 command took too long. Open T3 Code once, then try again."
                : "T3 Code did not give a token. Open T3 Code once, then try again."
            await apply(searchPath: path, scopeKnown: true)
            return
        }
        guard secrets.save(token) else {
            failure = "Waggle could not save the token in the Keychain."
            await apply(searchPath: path, scopeKnown: true)
            return
        }
        meta.setExpiry(now().addingTimeInterval(TimeInterval(T3Command.ttlDays) * 86_400))
        meta.setRemindedFor(nil)
        await apply(searchPath: path, scopeKnown: true)
    }

    /// Deletes the token from the Keychain, and asks T3 Code to end the sessions Waggle made when
    /// the CLI is there. The local delete never waits on that.
    func disconnect() async {
        guard !busy else { return }
        busy = true
        failure = nil
        defer { busy = false }
        secrets.delete()
        meta.setExpiry(nil)
        meta.setRemindedFor(nil)
        let path = await resolvePath().path
        if let cli = T3Command.findCLI(searchPath: path, homeDirectory: homeDirectory, fileManager: fileManager) {
            let list = await runner.run(executable: cli, arguments: T3Command.listArguments, searchPath: path, timeout: T3Command.revokeTimeout)
            if list.succeeded {
                for id in T3Command.waggleSessionIDs(listJSON: list.stdout) {
                    _ = await runner.run(
                        executable: cli, arguments: T3Command.revokeArguments(sessionID: id), searchPath: path,
                        timeout: T3Command.revokeTimeout)
                }
            }
        }
        await apply(searchPath: path)
    }
}

/// The one quiet reminder, three days before the token ends. No other prompt.
enum T3RenewReminder {
    static let leadDays = 3
    static let text = "T3 Code: renew the connection in Settings"

    /// Due once per token: inside the last three days, not yet ended, not sent for this end date.
    static func isDue(expiry: Date?, remindedFor: Date?, now: Date) -> Bool {
        guard let expiry, expiry > now else { return false }
        guard expiry.timeIntervalSince(now) <= TimeInterval(leadDays) * 86_400 else { return false }
        return remindedFor != expiry
    }

    /// Posts through `post` at most once per token. Reads no Keychain item.
    @discardableResult
    static func check(meta: T3MetaStoring, now: Date, post: () -> Void) -> Bool {
        guard isDue(expiry: meta.expiry, remindedFor: meta.remindedFor, now: now) else { return false }
        post()
        meta.setRemindedFor(meta.expiry)
        return true
    }
}

/// Whether the Start menu rows for T3 Code can work now, as a reason when they cannot.
enum T3Readiness {
    static func status(
        appInstalled: Bool, scopeSupported: Bool?, tokenPresent: Bool, expiry: Date?, server: T3Runtime.Status, now: Date
    ) -> SupersetStatus {
        guard appInstalled else { return .blocked(.notOnMac) }
        // `false`: the t3 command cannot limit a token. The row opens T3 and copies the prompt.
        if scopeSupported == false { return .ready }
        guard tokenPresent, let expiry, expiry > now else { return .blocked(.connectT3) }
        guard case .running = server else { return .blocked(.openT3) }
        return .ready
    }
}
