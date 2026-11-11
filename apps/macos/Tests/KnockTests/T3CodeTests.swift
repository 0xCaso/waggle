import AppKit
import Foundation
import Testing
@testable import Knock

// WAG-264: T3 Code launch target and Settings card. No test runs the real `t3`, contacts a real T3
// server, opens a real app or touches the real Keychain: fakes stand in for all of them.

private let secretToken = "tok_SECRET_0123456789abcdef"

private final class FakeSecrets: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    var saveSucceeds = true
    private(set) var saveCount = 0
    init(_ initial: String? = nil) { value = initial }
    func load() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ secret: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        saveCount += 1
        if saveSucceeds { value = secret }
        return saveSucceeds
    }
    func delete() { lock.lock(); value = nil; lock.unlock() }
}

private final class FakeMeta: T3MetaStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _expiry: Date?
    private var _reminded: Date?
    init(expiry: Date? = nil) { _expiry = expiry }
    var expiry: Date? { lock.lock(); defer { lock.unlock() }; return _expiry }
    var remindedFor: Date? { lock.lock(); defer { lock.unlock() }; return _reminded }
    func setExpiry(_ date: Date?) { lock.lock(); _expiry = date; lock.unlock() }
    func setRemindedFor(_ date: Date?) { lock.lock(); _reminded = date; lock.unlock() }
}

private final class FakeCLI: CLIRunning, @unchecked Sendable {
    struct Call: Equatable { var executable: String; var arguments: [String]; var timeout: TimeInterval }
    private let lock = NSLock()
    private var _calls: [Call] = []
    // `t3 auth session issue --help` lists `--scope` unless a test says otherwise.
    private var results: [String: CLIResult] = ["auth session issue --help": CLIResult(exitCode: 0, stdout: "  --scope <scope>  Repeatable\n  --ttl", stderr: "")]
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    /// Keyed by the first four, three or one arguments ("auth session issue --help", "auth session list", "app").
    func stub(_ key: String, _ result: CLIResult) { lock.lock(); results[key] = result; lock.unlock() }
    func run(executable: String, arguments: [String], searchPath: String, timeout: TimeInterval) async -> CLIResult {
        lock.withLock {
            _calls.append(Call(executable: executable, arguments: arguments, timeout: timeout))
            for count in [4, 3, 1] {
                if let hit = results[arguments.prefix(count).joined(separator: " ")] { return hit }
            }
            return CLIResult(exitCode: 1, stdout: "", stderr: "unstubbed")
        }
    }
}

private final class FakeT3App: ExternalAppOpening, @unchecked Sendable {
    var installed = true
    func isAppInstalled(bundleIdentifier: String) -> Bool { installed && bundleIdentifier == T3Runtime.bundleID }
    func appURL(toOpen url: URL) -> URL? { nil }
    func isRunning(appURL: URL) -> Bool { true }
    func launchApp(at appURL: URL) {}
    func open(url: URL) -> Bool { true }
}

private final class FakeServer: T3Serving, @unchecked Sendable {
    private let lock = NSLock()
    var projects: [T3Project] = []
    var listError: Error?
    var createError: Error?
    var launchError: Error?
    var runtimeMode: String?
    var modeError: Error?
    private(set) var modeAsked: [String] = []
    private(set) var created: [(origin: URL, token: String, title: String, root: String)] = []
    private(set) var launched: [(origin: URL, token: String, request: T3LaunchRequest)] = []
    private(set) var listCount = 0

    func listProjects(origin: URL, token: String) async throws -> [T3Project] {
        try lock.withLock {
            listCount += 1
            if let listError { throw listError }
            return projects
        }
    }
    func createProject(origin: URL, token: String, title: String, workspaceRoot: String) async throws -> T3Project {
        try lock.withLock {
            if let createError { throw createError }
            created.append((origin, token, title, workspaceRoot))
            return T3Project(id: "new-project", title: title, workspaceRoot: workspaceRoot)
        }
    }
    func projectRuntimeMode(origin: URL, token: String, projectID: String) async throws -> String? {
        try lock.withLock {
            modeAsked.append(projectID)
            if let modeError { throw modeError }
            return runtimeMode
        }
    }
    func launchThread(origin: URL, token: String, request: T3LaunchRequest) async throws {
        try lock.withLock {
            if let launchError { throw launchError }
            launched.append((origin, token, request))
        }
    }
}

private func ok(_ stdout: String = "") -> CLIResult { CLIResult(exitCode: 0, stdout: stdout, stderr: "") }

/// A temp folder with an executable `t3` in it (the fake runner never runs it).
private func makeBin(withT3: Bool = true) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("knock-t3-bin-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if withT3 {
        let file = dir.appendingPathComponent("t3")
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    return dir
}

/// A temp home with `~/.t3/userdata/server-runtime.json` naming `origin` and this very process.
private func makeHome(origin: String? = "http://127.0.0.1:3773", pid: Int = Int(ProcessInfo.processInfo.processIdentifier), sub: String = "userdata") throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("knock-t3-home-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    if let origin {
        let dir = home.appendingPathComponent(".t3/\(sub)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = "{\"version\":1,\"pid\":\(pid),\"port\":3773,\"origin\":\"\(origin)\",\"startedAt\":\"2026-10-07T00:00:00Z\"}"
        try json.write(to: dir.appendingPathComponent("server-runtime.json"), atomically: true, encoding: .utf8)
    }
    return home
}

// MARK: - Settings card state machine

struct T3CardStateTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func state(app: Bool = true, cli: Bool = true, scope: Bool = true, token: Bool = false, days: Double? = nil) -> T3CardState {
        T3CardState.resolve(
            appInstalled: app, cliFound: cli, scopeSupported: scope, hasToken: token,
            expiry: days.map { now.addingTimeInterval($0 * 86_400) }, now: now)
    }

    @Test func eachStateComesFromTheFourFacts() {
        #expect(state(app: false) == .notOnMac)
        #expect(state(app: false, cli: true, token: true, days: 10) == .notOnMac)
        #expect(state(cli: false) == .installCLI)
        #expect(state() == .notConnected)
        #expect(state(token: true, days: 30) == .connected(daysLeft: 30))
        #expect(state(token: true, days: -1) == .expired)
        #expect(state(token: true, days: nil) == .expired)
    }

    @Test func aCommandWithoutScopeNeverOffersConnect() {
        #expect(state(scope: false) == .scopeUnsupported)
        #expect(state(scope: false, token: true, days: 10) == .scopeUnsupported)
        #expect(state(app: false, scope: false) == .notOnMac)
        // No command at all is still the install state, whatever the scope flag says.
        #expect(state(cli: false, scope: false) == .installCLI)
        #expect(T3CardState.scopeUnsupported.help == "Your T3 Code version cannot limit access yet. Waggle opens T3 and copies the prompt until you update.")
    }

    @Test func aTokenKeepsWorkingWithoutTheCommandUntilItEnds() {
        #expect(state(cli: false, token: true, days: 5) == .connected(daysLeft: 5))
        #expect(state(cli: false, token: true, days: -1) == .installCLI)
    }

    @Test func daysRoundUpAndNeverReadZero() {
        #expect(T3CardState.daysLeft(until: now.addingTimeInterval(3600), now: now) == 1)
        #expect(T3CardState.daysLeft(until: now.addingTimeInterval(86_400 * 2 + 60), now: now) == 3)
        #expect(T3CardState.daysLeft(until: now.addingTimeInterval(86_400 * 30), now: now) == 30)
    }

    @Test func titlesAndHelpUsePlainWords() {
        #expect(T3CardState.notOnMac.title == "Not on this Mac")
        #expect(T3CardState.installCLI.title == "Install the t3 command")
        #expect(T3CardState.notConnected.title == "Not connected")
        #expect(T3CardState.connected(daysLeft: 12).title == "Connected · renews in 12 days")
        #expect(T3CardState.connected(daysLeft: 1).title == "Connected · renews in 1 day")
        #expect(T3CardState.expired.title == "Expired")
        for s in [T3CardState.notOnMac, .installCLI, .scopeUnsupported, .notConnected, .connected(daysLeft: 3), .expired] {
            #expect(!s.help.contains("\u{2014}"))
            #expect(!s.help.contains("\n"))
        }
        #expect(T3Command.installLine == "curl -fsSL https://t3.codes/install.sh | sh")
    }
}

// MARK: - Command lines

struct T3CommandTests {
    @Test func issueLineAlwaysAsksForTheTwoScopes() {
        #expect(T3Command.issueArguments() == [
            "auth", "session", "issue", "--scope", "orchestration:read", "--scope", "orchestration:operate",
            "--ttl", "30d", "--label", "Waggle", "--subject", "waggle", "--token-only",
        ])
    }

    @Test func scopeSupportComesFromTheHelpText() async {
        #expect(T3Command.supportsScope(helpText: "Options:\n  --scope <scope>  Repeatable"))
        // 0.0.46-nightly.20261005 has no `--scope` flag.
        #expect(!T3Command.supportsScope(helpText: "Options:\n  --ttl <ttl>\n  --token-only"))
        let runner = FakeCLI()
        #expect(await T3Command.probeScope(runner: runner, cli: "/x/t3", searchPath: "/x"))
        runner.stub("auth session issue --help", CLIResult(exitCode: 1, stdout: "", stderr: "", timedOut: true))
        #expect(!(await T3Command.probeScope(runner: runner, cli: "/x/t3", searchPath: "/x")))
    }

    @Test func tokenIsOneLineWithoutSpaces() {
        #expect(T3Command.token(from: "abc123\n") == "abc123")
        #expect(T3Command.token(from: "") == nil)
        #expect(T3Command.token(from: "Issued bearer access token x.\nToken: y") == nil)
    }

    @Test func onlyWaggleSessionsAreRevoked() {
        let json = """
        [{"sessionId":"s-1","subject":"waggle"},{"sessionId":"s-2","subject":"someone"},{"sessionId":"s-3","subject":"waggle"},{"subject":"waggle"}]
        """
        #expect(T3Command.waggleSessionIDs(listJSON: json) == ["s-1", "s-3"])
        #expect(T3Command.waggleSessionIDs(listJSON: "nope") == [])
        #expect(T3Command.revokeArguments(sessionID: "s-1") == ["auth", "session", "revoke", "s-1"])
        #expect(T3Command.appArguments(folder: "/a b") == ["app", "/a b"])
    }

    @Test func theCLIIsFoundOnPathOrInTheInstallFolders() throws {
        let bin = try makeBin()
        let empty = try makeBin(withT3: false)
        let home = try makeBin(withT3: false)
        defer { for d in [bin, empty, home] { try? FileManager.default.removeItem(at: d) } }
        #expect(T3Command.findCLI(searchPath: bin.path, homeDirectory: home.path) == bin.appendingPathComponent("t3").path)
        #expect(T3Command.findCLI(searchPath: empty.path, homeDirectory: home.path) == nil)
        let local = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bin.appendingPathComponent("t3"), to: local.appendingPathComponent("t3"))
        #expect(T3Command.findCLI(searchPath: empty.path, homeDirectory: home.path) == local.appendingPathComponent("t3").path)
    }
}

// MARK: - Connect, renew, disconnect

@MainActor
struct T3ConnectionModelTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func make(
        secrets: FakeSecrets = FakeSecrets(), meta: FakeMeta = FakeMeta(), runner: FakeCLI = FakeCLI(),
        app: FakeT3App = FakeT3App(), bin: URL?, home: String = "/nonexistent-home"
    ) -> T3ConnectionModel {
        let path = bin?.path ?? "/nonexistent-bin"
        return T3ConnectionModel(
            secrets: secrets, meta: meta, runner: runner, opener: app,
            resolvePath: { LoginShellPathResolution(path: path, shellSucceeded: true) },
            homeDirectory: home, now: { [now] in now })
    }

    @Test func connectStoresTheTokenInTheKeychainAndTheExpiryAside() async throws {
        let bin = try makeBin()
        defer { try? FileManager.default.removeItem(at: bin) }
        let secrets = FakeSecrets(), meta = FakeMeta(), runner = FakeCLI()
        runner.stub("auth session issue", ok(secretToken + "\n"))
        let model = make(secrets: secrets, meta: meta, runner: runner, bin: bin)
        await model.refresh()
        #expect(model.state == .notConnected)
        await model.connect()
        #expect(secrets.load() == secretToken)
        #expect(meta.expiry == now.addingTimeInterval(30 * 86_400))
        #expect(model.state == .connected(daysLeft: 30))
        #expect(model.failure == nil)
        let issue = try #require(runner.calls.first { $0.arguments.contains("--token-only") })
        #expect(issue.arguments.filter { $0 == "--scope" }.count == 2)
        #expect(issue.arguments == T3Command.issueArguments())
        #expect(issue.timeout == T3Command.issueTimeout)
        #expect(issue.executable == bin.appendingPathComponent("t3").path)
    }

    @Test func anUnscopedCommandNeverIssuesAToken() async throws {
        let bin = try makeBin()
        defer { try? FileManager.default.removeItem(at: bin) }
        let secrets = FakeSecrets(), meta = FakeMeta(), runner = FakeCLI()
        runner.stub("auth session issue --help", ok("Options:\n  --ttl <ttl>\n  --token-only"))
        runner.stub("auth session issue", ok(secretToken))
        let model = make(secrets: secrets, meta: meta, runner: runner, bin: bin)
        await model.refresh()
        #expect(model.state == .scopeUnsupported)
        await model.connect()
        #expect(model.state == .scopeUnsupported)
        #expect(secrets.load() == nil)
        #expect(secrets.saveCount == 0)
        #expect(meta.expiry == nil)
        #expect(!runner.calls.contains { $0.arguments.contains("--token-only") })
    }

    @Test func aTokenLeftByAnUnscopedCommandIsRemoved() async throws {
        let bin = try makeBin()
        defer { try? FileManager.default.removeItem(at: bin) }
        let secrets = FakeSecrets(secretToken), meta = FakeMeta(expiry: now.addingTimeInterval(86_400 * 9)), runner = FakeCLI()
        runner.stub("auth session issue --help", ok("Options: --ttl"))
        let model = make(secrets: secrets, meta: meta, runner: runner, bin: bin)
        await model.refresh()
        #expect(model.state == .scopeUnsupported)
        #expect(secrets.load() == nil)
        #expect(meta.expiry == nil)
    }

    @Test func theTokenNeverLeavesTheKeychainFake() async throws {
        let bin = try makeBin()
        defer { try? FileManager.default.removeItem(at: bin) }
        let suite = "knock-t3-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = FakeSecrets(), runner = FakeCLI()
        runner.stub("auth session issue", ok(secretToken))
        let model = T3ConnectionModel(
            secrets: secrets, meta: UserDefaultsT3Meta(defaults: defaults), runner: runner, opener: FakeT3App(),
            resolvePath: { LoginShellPathResolution(path: bin.path, shellSucceeded: true) },
            homeDirectory: "/nonexistent-home", now: { [now] in now })
        await model.connect()
        #expect(secrets.load() == secretToken)
        let stored = defaults.dictionaryRepresentation().map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        #expect(!stored.contains(secretToken))
        #expect(defaults.object(forKey: UserDefaultsT3Meta.expiryKey) != nil)
        let shown = "\(model.state.title) \(model.state.help) \(model.failure ?? "")"
        #expect(!shown.contains(secretToken))
    }

    @Test func aFailedConnectSaysSoWithoutQuotingTheCommandOutput() async throws {
        let bin = try makeBin()
        defer { try? FileManager.default.removeItem(at: bin) }
        let secrets = FakeSecrets(), meta = FakeMeta(), runner = FakeCLI()
        runner.stub("auth session issue", CLIResult(exitCode: 2, stdout: secretToken, stderr: "boom \(secretToken)"))
        let model = make(secrets: secrets, meta: meta, runner: runner, bin: bin)
        await model.connect()
        #expect(secrets.load() == nil)
        #expect(meta.expiry == nil)
        #expect(model.state == .notConnected)
        let failure = try #require(model.failure)
        #expect(!failure.contains(secretToken))
        #expect(failure == "T3 Code did not give a token. Open T3 Code once, then try again.")
        runner.stub("auth session issue", CLIResult(exitCode: -1, stdout: "", stderr: "", timedOut: true))
        await model.connect()
        #expect(model.failure == "The t3 command took too long. Open T3 Code once, then try again.")
    }

    @Test func noCommandMeansNoRunAndTheInstallState() async throws {
        let none = try makeBin(withT3: false)
        defer { try? FileManager.default.removeItem(at: none) }
        let runner = FakeCLI()
        let model = make(runner: runner, bin: none)
        await model.refresh()
        #expect(model.state == .installCLI)
        await model.connect()
        #expect(runner.calls.isEmpty)
        #expect(model.failure == "Waggle could not find the t3 command. Install it first.")
    }

    @Test func noAppIsNotOnThisMac() async throws {
        let bin = try makeBin()
        defer { try? FileManager.default.removeItem(at: bin) }
        let app = FakeT3App()
        app.installed = false
        let model = make(app: app, bin: bin)
        await model.refresh()
        #expect(model.state == .notOnMac)
    }

    @Test func aKeychainFailureSavesNoExpiry() async throws {
        let bin = try makeBin()
        defer { try? FileManager.default.removeItem(at: bin) }
        let secrets = FakeSecrets(), meta = FakeMeta(), runner = FakeCLI()
        secrets.saveSucceeds = false
        runner.stub("auth session issue", ok(secretToken))
        let model = make(secrets: secrets, meta: meta, runner: runner, bin: bin)
        await model.connect()
        #expect(meta.expiry == nil)
        #expect(model.failure == "Waggle could not save the token in the Keychain.")
    }

    @Test func renewReplacesTheTokenAndClearsTheReminderMark() async throws {
        let bin = try makeBin()
        defer { try? FileManager.default.removeItem(at: bin) }
        let oldEnd = now.addingTimeInterval(-60)
        let secrets = FakeSecrets("old-token"), meta = FakeMeta(expiry: oldEnd), runner = FakeCLI()
        meta.setRemindedFor(oldEnd)
        runner.stub("auth session issue", ok("new-token"))
        let model = make(secrets: secrets, meta: meta, runner: runner, bin: bin)
        await model.refresh()
        #expect(model.state == .expired)
        await model.connect()
        #expect(secrets.load() == "new-token")
        #expect(meta.remindedFor == nil)
        #expect(model.state == .connected(daysLeft: 30))
    }

    @Test func disconnectDeletesLocallyAndRevokesOnlyWaggleSessions() async throws {
        let bin = try makeBin()
        defer { try? FileManager.default.removeItem(at: bin) }
        let secrets = FakeSecrets(secretToken), meta = FakeMeta(expiry: now.addingTimeInterval(86_400 * 9)), runner = FakeCLI()
        runner.stub("auth session list", ok("[{\"sessionId\":\"s-1\",\"subject\":\"waggle\"},{\"sessionId\":\"s-2\",\"subject\":\"other\"}]"))
        runner.stub("auth session revoke", ok("Revoked"))
        let model = make(secrets: secrets, meta: meta, runner: runner, bin: bin)
        await model.refresh()
        #expect(model.state == .connected(daysLeft: 9))
        await model.disconnect()
        #expect(secrets.load() == nil)
        #expect(meta.expiry == nil)
        #expect(model.state == .notConnected)
        let revokes = runner.calls.filter { $0.arguments.prefix(3) == ["auth", "session", "revoke"] }
        #expect(revokes.map(\.arguments) == [["auth", "session", "revoke", "s-1"]])
    }

    @Test func disconnectStillDeletesWhenNoCommandIsThere() async throws {
        let none = try makeBin(withT3: false)
        defer { try? FileManager.default.removeItem(at: none) }
        let secrets = FakeSecrets(secretToken), meta = FakeMeta(expiry: now.addingTimeInterval(86_400))
        let runner = FakeCLI()
        let model = make(secrets: secrets, meta: meta, runner: runner, bin: none)
        await model.disconnect()
        #expect(secrets.load() == nil)
        #expect(meta.expiry == nil)
        #expect(runner.calls.isEmpty)
    }
}

// MARK: - The 3-day reminder

struct T3RenewReminderTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func days(_ n: Double) -> Date { now.addingTimeInterval(n * 86_400) }

    @Test func dueOnlyInTheLastThreeDays() {
        #expect(!T3RenewReminder.isDue(expiry: nil, remindedFor: nil, now: now))
        #expect(!T3RenewReminder.isDue(expiry: days(30), remindedFor: nil, now: now))
        #expect(!T3RenewReminder.isDue(expiry: days(3.01), remindedFor: nil, now: now))
        #expect(T3RenewReminder.isDue(expiry: days(3), remindedFor: nil, now: now))
        #expect(T3RenewReminder.isDue(expiry: days(0.1), remindedFor: nil, now: now))
        #expect(!T3RenewReminder.isDue(expiry: days(-0.1), remindedFor: nil, now: now))
    }

    @Test func oneReminderPerTokenAndOneLineOfText() {
        let meta = FakeMeta(expiry: days(2))
        var posted = 0
        #expect(T3RenewReminder.check(meta: meta, now: now) { posted += 1 })
        #expect(!T3RenewReminder.check(meta: meta, now: now.addingTimeInterval(3600)) { posted += 1 })
        #expect(posted == 1)
        // A renewed token has a new end date and gets its own reminder later.
        meta.setExpiry(days(30))
        #expect(!T3RenewReminder.isDue(expiry: meta.expiry, remindedFor: meta.remindedFor, now: now))
        #expect(T3RenewReminder.isDue(expiry: meta.expiry, remindedFor: meta.remindedFor, now: days(28)))
        #expect(T3RenewReminder.text == "T3 Code: renew the connection in Settings")
    }

    @Test func nothingIsPostedWithoutAConnection() {
        var posted = 0
        #expect(!T3RenewReminder.check(meta: FakeMeta(), now: now) { posted += 1 })
        #expect(posted == 0)
    }
}

// MARK: - Loopback only

struct T3LoopbackTests {
    @Test func onlyAddressesOnThisMacPass() {
        #expect(T3Runtime.loopbackOrigin("http://127.0.0.1:3773")?.absoluteString == "http://127.0.0.1:3773")
        #expect(T3Runtime.loopbackOrigin("http://localhost:3773")?.host == "localhost")
        #expect(T3Runtime.loopbackOrigin("http://[::1]:3773")?.port == 3773)
        #expect(T3Runtime.loopbackOrigin("http://127.0.0.1:3773/mcp?x=1")?.absoluteString == "http://127.0.0.1:3773")
    }

    @Test func everythingElseIsRefused() {
        for bad in [
            "http://192.168.1.5:3773", "http://10.0.0.2:3773", "http://example.com:3773", "http://0.0.0.0:3773",
            "http://localhost.evil.com:3773", "http://127.0.0.1.evil.com:3773", "http://127.0.0.1@evil.com:3773",
            "http://user:pw@127.0.0.1:3773", "http://127.0.0.1", "ftp://127.0.0.1:3773", "ws://127.0.0.1:3773",
            "", "not a url", "http://[::2]:3773", "http://127.0.0.2:3773",
        ] {
            #expect(T3Runtime.loopbackOrigin(bad) == nil, "\(bad)")
        }
    }

    @Test func serverFileGivesRunningStaleRefusedOrAbsent() throws {
        let good = try makeHome()
        let stale = try makeHome(pid: 2_000_000_000)
        let remote = try makeHome(origin: "http://10.1.2.3:3773")
        let none = try makeHome(origin: nil)
        let dev = try makeHome(sub: "dev")
        defer { for h in [good, stale, remote, none, dev] { try? FileManager.default.removeItem(at: h) } }
        func status(_ home: URL, env: [String: String] = [:]) -> T3Runtime.Status {
            T3Runtime.serverStatus(homeDirectory: home.path, environment: env)
        }
        #expect(status(good) == .running(origin: URL(string: "http://127.0.0.1:3773")!))
        #expect(status(stale) == .notRunning)
        #expect(status(remote) == .refused)
        #expect(status(none) == .notRunning)
        #expect(status(dev) == .running(origin: URL(string: "http://127.0.0.1:3773")!))
    }

    @Test func t3CodeHomeMovesTheFolderAndDropsTheDevOne() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("knock-t3-custom-\(UUID().uuidString)")
        let dir = base.appendingPathComponent("userdata")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = "{\"version\":1,\"pid\":\(ProcessInfo.processInfo.processIdentifier),\"port\":4000,\"origin\":\"http://localhost:4000\"}"
        try json.write(to: dir.appendingPathComponent("server-runtime.json"), atomically: true, encoding: .utf8)
        let empty = try makeHome(origin: nil)
        defer { for d in [base, empty] { try? FileManager.default.removeItem(at: d) } }
        #expect(T3Runtime.stateDirectories(homeDirectory: "/h", environment: ["T3CODE_HOME": "~/x"]) == ["/h/x/userdata"])
        #expect(T3Runtime.stateDirectories(homeDirectory: "/h", environment: [:]) == ["/h/.t3/userdata", "/h/.t3/dev"])
        let status = T3Runtime.serverStatus(homeDirectory: empty.path, environment: ["T3CODE_HOME": base.path])
        #expect(status == .running(origin: URL(string: "http://localhost:4000")!))
    }

    @Test func theClientRefusesAForeignOriginBeforeAnyRequest() async {
        StubURLProtocol.reset()
        let client = T3HTTPServer(session: StubURLProtocol.session())
        let foreign = URL(string: "http://203.0.113.9:3773")!
        await #expect(throws: T3Error.notLoopback) { try await client.listProjects(origin: foreign, token: "t") }
        await #expect(throws: T3Error.notLoopback) { try await client.createProject(origin: foreign, token: "t", title: "x", workspaceRoot: "/x") }
        let request = T3LaunchRequest(projectID: "p", title: "t", agent: .claude, model: "m", prompt: "hi")
        await #expect(throws: T3Error.notLoopback) { try await client.launchThread(origin: foreign, token: "t", request: request) }
        #expect(StubURLProtocol.requests.isEmpty)
    }
}

// MARK: - Wire format and the real client (HTTP stubbed, socket faked)

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var responses: [String: (Int, String)] = [:]
    static func reset() { requests = []; responses = [:] }
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var copy = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            copy.httpBody = data
        }
        Self.requests.append(copy)
        let path = request.url?.path ?? ""
        let (status, body) = Self.responses[path] ?? (404, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class FakeSocket: T3RPCSocket, @unchecked Sendable {
    var outcome: T3Wire.Outcome = .success
    private(set) var calls: [(url: URL, frame: Data, id: String)] = []
    func call(url: URL, frame: Data, id: String, timeout: TimeInterval) async throws -> T3Wire.Outcome {
        calls.append((url, frame, id))
        return outcome
    }
}

@Suite(.serialized)
struct T3WireTests {
    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func launchPayloadCarriesAgentPromptAndProject() throws {
        let prompt = "Read \"/a b/it's.md\".\nUse $HOME `x` & 'done'"
        let request = T3LaunchRequest(projectID: "p-1", title: "My PRD", agent: .codex, model: "gpt-6-astra", prompt: prompt)
        let payload = T3Wire.launchPayload(commandID: "c-1", request: request)
        let data = try JSONSerialization.data(withJSONObject: payload)
        let json = try object(data)
        #expect(json["commandId"] as? String == "c-1")
        #expect(json["projectId"] as? String == "p-1")
        #expect(json["title"] as? String == "My PRD")
        #expect(json["runtimeMode"] as? String == "approval-required")
        #expect(json["interactionMode"] as? String == "default")
        let model = try #require(json["modelSelection"] as? [String: String])
        #expect(model == ["instanceId": "codex", "model": "gpt-6-astra"])
        let strategy = try #require(json["workspaceStrategy"] as? [String: String])
        #expect(strategy == ["type": "root"])
        let message = try #require(json["initialMessage"] as? [String: Any])
        #expect(message["text"] as? String == prompt)
        #expect((message["attachments"] as? [Any])?.isEmpty == true)
        let claude = T3Wire.launchPayload(commandID: "c", request: T3LaunchRequest(projectID: "p", title: "t", agent: .claude, model: "m", prompt: "x"))
        #expect((claude["modelSelection"] as? [String: String])?["instanceId"] == "claudeAgent")
    }

    @Test func runtimeModeComesFromTheProjectAndFallsBackToApprovalRequired() throws {
        func mode(_ request: T3LaunchRequest) -> String? {
            T3Wire.launchPayload(commandID: "c", request: request)["runtimeMode"] as? String
        }
        var request = T3LaunchRequest(projectID: "p", title: "t", agent: .claude, model: "m", prompt: "x")
        #expect(mode(request) == "approval-required")
        request.runtimeMode = "full-access"
        #expect(mode(request) == "full-access")
        request.runtimeMode = "auto-accept-edits"
        #expect(mode(request) == "auto-accept-edits")
    }

    @Test func projectModeIsReadFromTheSettingsOverrides() throws {
        let settings: [String: Any] = ["projectSettingsOverrides": [
            "p-1": ["defaultRuntimeMode": "auto"], "p-2": ["defaultRuntimeMode": "bogus"], "p-3": ["defaultModelSelection": NSNull()],
        ]]
        #expect(T3Wire.runtimeMode(settings: settings, projectID: "p-1") == "auto")
        #expect(T3Wire.runtimeMode(settings: settings, projectID: "p-2") == nil)
        #expect(T3Wire.runtimeMode(settings: settings, projectID: "p-3") == nil)
        #expect(T3Wire.runtimeMode(settings: settings, projectID: "p-4") == nil)
        #expect(T3Wire.runtimeMode(settings: nil, projectID: "p-1") == nil)
    }

    @Test func realClientReadsTheProjectModeOverTheSocket() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.responses["/api/auth/websocket-ticket"] = (200, #"{"ticket":"tk"}"#)
        let socket = FakeSocket()
        socket.outcome = .value(Data(#"{"v":{"projectSettingsOverrides":{"p-1":{"defaultRuntimeMode":"full-access"}}}}"#.utf8))
        let client = T3HTTPServer(session: StubURLProtocol.session(), socket: socket, newID: { "id-1" })
        let origin = URL(string: "http://127.0.0.1:3773")!
        #expect(try await client.projectRuntimeMode(origin: origin, token: "t", projectID: "p-1") == "full-access")
        #expect(try await client.projectRuntimeMode(origin: origin, token: "t", projectID: "p-2") == nil)
        #expect(try object(try #require(socket.calls.first).frame)["tag"] as? String == "server.getSettings")
        socket.outcome = .failure("denied")
        await #expect(throws: T3Error.rejected("denied")) { try await client.projectRuntimeMode(origin: origin, token: "t", projectID: "p-1") }
        await #expect(throws: T3Error.notLoopback) {
            try await client.projectRuntimeMode(origin: URL(string: "http://203.0.113.9:3773")!, token: "t", projectID: "p")
        }
    }

    @Test func frameIsOneEffectRPCRequest() throws {
        let frame = T3Wire.rpcFrame(id: "7", tag: T3Wire.launchTag, payload: ["a": 1])
        let json = try object(frame)
        #expect(json["_tag"] as? String == "Request")
        #expect(json["id"] as? String == "7")
        #expect(json["tag"] as? String == "orchestration.launchThread")
        #expect((json["headers"] as? [Any])?.isEmpty == true)
    }

    @Test func answerIsMatchedByRequestId() {
        func frame(_ text: String) -> Data { Data(text.utf8) }
        #expect(T3Wire.outcome(frame: frame(#"{"_tag":"Exit","requestId":"7","exit":{"_tag":"Success"}}"#), id: "7") == .success)
        #expect(T3Wire.outcome(frame: frame(#"{"_tag":"Exit","requestId":"7","exit":{"_tag":"Success","value":{"a":1}}}"#), id: "7") == .value(Data(#"{"v":{"a":1}}"#.utf8)))
        #expect(T3Wire.outcome(frame: frame(#"[{"_tag":"Pong"},{"_tag":"Exit","requestId":"7","exit":{"_tag":"Success"}}]"#), id: "7") == .success)
        #expect(T3Wire.outcome(frame: frame(#"{"_tag":"Exit","requestId":"8","exit":{"_tag":"Success","value":1}}"#), id: "7") == nil)
        #expect(T3Wire.outcome(frame: frame(#"{"_tag":"Pong"}"#), id: "7") == nil)
        #expect(T3Wire.outcome(frame: frame("garbage"), id: "7") == nil)
        let failure = #"{"_tag":"Exit","requestId":"7","exit":{"_tag":"Failure","cause":[{"_tag":"Fail","error":{"_tag":"ThreadLaunchError","message":"no such project"}}]}}"#
        #expect(T3Wire.outcome(frame: frame(failure), id: "7") == .failure("no such project"))
    }

    @Test func projectsParseWithDeletedAndDefaultModel() throws {
        let json = #"""
        {"projects":[{"id":"p-1","title":"waggle","workspaceRoot":"/w","defaultModelSelection":{"instanceId":"codex","model":"gpt-x"},"deletedAt":null},
        {"id":"p-2","title":"old","workspaceRoot":"/o","defaultModelSelection":null,"deletedAt":"2026-10-01T00:00:00Z"}],"updatedAt":"x"}
        """#
        let projects = try #require(T3Wire.parseProjects(Data(json.utf8)))
        #expect(projects[0] == T3Project(id: "p-1", title: "waggle", workspaceRoot: "/w", deleted: false, defaultInstanceID: "codex", defaultModel: "gpt-x"))
        #expect(projects[1].deleted)
        #expect(T3Wire.parseProjects(Data("[]".utf8)) == nil)
    }

    @Test func realClientSendsBearerListsAndCreatesProjects() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.responses["/api/projects"] = (200, #"{"projects":[{"id":"p-1","title":"a","workspaceRoot":"/a","defaultModelSelection":null,"deletedAt":null}],"updatedAt":"x"}"#)
        StubURLProtocol.responses["/api/projects/mutate"] = (200, #"{"id":"p-9","title":"b","workspaceRoot":"/b","defaultModelSelection":null,"deletedAt":null}"#)
        let client = T3HTTPServer(session: StubURLProtocol.session(), newID: { "id-1" })
        let origin = URL(string: "http://127.0.0.1:3773")!
        let list = try await client.listProjects(origin: origin, token: "tok")
        #expect(list.map(\.id) == ["p-1"])
        let created = try await client.createProject(origin: origin, token: "tok", title: "b", workspaceRoot: "/b")
        #expect(created.id == "p-9")
        let get = try #require(StubURLProtocol.requests.first)
        #expect(get.httpMethod == "GET")
        #expect(get.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(get.value(forHTTPHeaderField: "x-t3-orchestration-protocol") == "2")
        let post = try #require(StubURLProtocol.requests.last)
        let body = try object(try #require(post.httpBody))
        #expect(body["type"] as? String == "project.create")
        #expect(body["workspaceRoot"] as? String == "/b")
        #expect(body["title"] as? String == "b")
        #expect(StubURLProtocol.requests.allSatisfy { $0.url?.host == "127.0.0.1" })
    }

    @Test func realClientTakesATicketThenCallsLaunchOverTheSocket() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.responses["/api/auth/websocket-ticket"] = (200, #"{"ticket":"tk 1"}"#)
        let socket = FakeSocket()
        let client = T3HTTPServer(session: StubURLProtocol.session(), socket: socket, newID: { "id-1" })
        let request = T3LaunchRequest(projectID: "p-1", title: "t", agent: .claude, model: "m", prompt: "hello")
        try await client.launchThread(origin: URL(string: "http://localhost:3773")!, token: "tok", request: request)
        let call = try #require(socket.calls.first)
        let url = try #require(URLComponents(url: call.url, resolvingAgainstBaseURL: false))
        #expect(url.scheme == "ws")
        #expect(url.host == "localhost")
        #expect(url.path == "/ws")
        #expect(url.queryItems?.first { $0.name == "orchestrationProtocol" }?.value == "2")
        #expect(url.queryItems?.first { $0.name == "wsTicket" }?.value == "tk 1")
        let json = try object(call.frame)
        #expect(json["tag"] as? String == "orchestration.launchThread")
        #expect(((json["payload"] as? [String: Any])?["initialMessage"] as? [String: Any])?["text"] as? String == "hello")
        socket.outcome = .failure("denied")
        await #expect(throws: T3Error.rejected("denied")) {
            try await client.launchThread(origin: URL(string: "http://localhost:3773")!, token: "tok", request: request)
        }
    }

    @Test func realClientReportsHTTPErrorsAndBadTickets() async {
        StubURLProtocol.reset()
        StubURLProtocol.responses["/api/projects"] = (401, "{}")
        StubURLProtocol.responses["/api/auth/websocket-ticket"] = (200, "{}")
        let client = T3HTTPServer(session: StubURLProtocol.session(), socket: FakeSocket())
        let origin = URL(string: "http://127.0.0.1:3773")!
        await #expect(throws: T3Error.http(401)) { try await client.listProjects(origin: origin, token: "x") }
        let request = T3LaunchRequest(projectID: "p", title: "t", agent: .claude, model: "m", prompt: "x")
        await #expect(throws: T3Error.badResponse) { try await client.launchThread(origin: origin, token: "x", request: request) }
    }
}

// MARK: - Launcher: match, create, send, every fallback

struct T3LauncherTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let prompt = "Read \"/tmp/My PRD.md\"\nand ask me."

    private struct Rig {
        var launcher: T3Launcher
        var server: FakeServer
        var runner: FakeCLI
        var secrets: FakeSecrets
        var meta: FakeMeta
        var bin: URL
        var home: URL
    }

    private func rig(
        token: String? = "tok-1", expiryDays: Double? = 20, serverOrigin: String? = "http://127.0.0.1:3773",
        withCLI: Bool = true, appWorks: Bool = true
    ) throws -> Rig {
        let bin = try makeBin(withT3: withCLI)
        let home = try makeHome(origin: serverOrigin)
        let server = FakeServer(), runner = FakeCLI()
        if appWorks { runner.stub("app", ok()) }
        let secrets = FakeSecrets(token)
        let meta = FakeMeta(expiry: expiryDays.map { now.addingTimeInterval($0 * 86_400) })
        let launcher = T3Launcher(
            secrets: secrets, meta: meta, server: server, runner: runner, homeDirectory: home.path,
            environment: [:], now: { [now] in now })
        return Rig(launcher: launcher, server: server, runner: runner, secrets: secrets, meta: meta, bin: bin, home: home)
    }

    private func clean(_ rig: Rig) { for d in [rig.bin, rig.home] { try? FileManager.default.removeItem(at: d) } }

    private func run(_ rig: Rig, target: LaunchTarget = .claudeT3, folder: String = "/Users/me/waggle") async -> T3LaunchResult {
        await rig.launcher.launch(target: target, folder: folder, topic: "My PRD", prompt: prompt, searchPath: rig.bin.path)
    }

    @Test func existingProjectIsMatchedByResolvedPathAndTheThreadStarts() async throws {
        let r = try rig()
        defer { clean(r) }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("knock-t3-proj-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real"), link = base.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: base) }
        r.server.projects = [
            T3Project(id: "gone", title: "x", workspaceRoot: real.path, deleted: true),
            T3Project(id: "other", title: "o", workspaceRoot: "/elsewhere"),
            T3Project(id: "match", title: "m", workspaceRoot: real.path + "/"),
        ]
        let result = await run(r, folder: link.path)
        #expect(result == .started)
        #expect(r.server.created.isEmpty)
        let launch = try #require(r.server.launched.first)
        #expect(launch.request.projectID == "match")
        #expect(launch.request.prompt == prompt)
        #expect(launch.request.agent.instanceID == "claudeAgent")
        #expect(launch.request.model == "claude-fable-5-1")
        #expect(launch.request.title == "My PRD")
        #expect(launch.token == "tok-1")
        #expect(launch.origin.absoluteString == "http://127.0.0.1:3773")
        let app = try #require(r.runner.calls.last)
        #expect(app.arguments == ["app", link.path])
        #expect(app.timeout == T3Command.appTimeout)
    }

    @Test func missingProjectIsCreatedForTheResolvedFolderThenUsed() async throws {
        let r = try rig()
        defer { clean(r) }
        let result = await run(r, target: .codexT3, folder: "/Users/me/waggle/")
        #expect(result == .started)
        let created = try #require(r.server.created.first)
        #expect(created.title == "waggle")
        #expect(created.root == SupersetCommand.normalizedPath("/Users/me/waggle"))
        let launch = try #require(r.server.launched.first)
        #expect(launch.request.projectID == "new-project")
        #expect(launch.request.agent.instanceID == "codex")
        #expect(launch.request.model == "gpt-6-astra")
    }

    @Test func runtimeModeIsTheProjectsOwnWhenItHasOne() async throws {
        let r = try rig()
        defer { clean(r) }
        r.server.projects = [T3Project(id: "p", title: "w", workspaceRoot: SupersetCommand.normalizedPath("/Users/me/waggle"))]
        r.server.runtimeMode = "full-access"
        #expect(await run(r) == .started)
        #expect(r.server.modeAsked == ["p"])
        #expect(r.server.launched.first?.request.runtimeMode == "full-access")
    }

    @Test func noProjectModeOrAFailedReadSendsApprovalRequired() async throws {
        let none = try rig(), broken = try rig()
        defer { clean(none); clean(broken) }
        broken.server.modeError = T3Error.http(500)
        #expect(await run(none) == .started)
        #expect(await run(broken) == .started)
        for r in [none, broken] {
            let request = try #require(r.server.launched.first?.request)
            #expect(request.runtimeMode == nil)
            let payload = T3Wire.launchPayload(commandID: "c", request: request)
            #expect(payload["runtimeMode"] as? String == "approval-required")
        }
    }

    @Test func anUnscopedCommandOpensAndPastesWithNoServerCall() async throws {
        let r = try rig()
        defer { clean(r) }
        r.runner.stub("auth session issue --help", ok("Options: --ttl"))
        let result = await run(r)
        #expect(result == .failed(T3Launcher.pasteOnly, copyPrompt: true))
        #expect(r.server.listCount == 0)
        #expect(r.server.launched.isEmpty)
        #expect(r.runner.calls.last?.arguments == ["app", "/Users/me/waggle"])
        #expect(!T3Launcher.pasteOnly.contains("\u{2014}"))
        // The app command fails too: say to open T3 and paste.
        let noApp = try rig(appWorks: false)
        defer { clean(noApp) }
        noApp.runner.stub("auth session issue --help", ok("Options: --ttl"))
        #expect(await run(noApp) == .failed(T3Launcher.fallbackNoApp, copyPrompt: true))
    }

    @Test func projectDefaultModelIsUsedOnlyForTheSameAgent() async throws {
        let r = try rig()
        defer { clean(r) }
        let root = SupersetCommand.normalizedPath("/Users/me/waggle")
        r.server.projects = [T3Project(id: "p", title: "w", workspaceRoot: root, defaultInstanceID: "codex", defaultModel: "gpt-custom")]
        _ = await run(r, target: .codexT3)
        _ = await run(r, target: .claudeT3)
        #expect(r.server.launched.map(\.request.model) == ["gpt-custom", "claude-fable-5-1"])
    }

    @Test func threadStartedButAppNotForwardIsSaidAndNotCopied() async throws {
        let r = try rig(appWorks: false)
        defer { clean(r) }
        let result = await run(r)
        #expect(result == .failed(T3Launcher.notShown, copyPrompt: false))
        #expect(r.server.launched.count == 1)
    }

    private func expectFallback(_ r: Rig, _ result: T3LaunchResult, expectLaunch: Int = 0) {
        #expect(result == .failed(T3Launcher.fallbackWithApp, copyPrompt: true))
        #expect(r.server.launched.count == expectLaunch)
        #expect(r.runner.calls.last?.arguments == ["app", "/Users/me/waggle"])
        #expect(!T3Launcher.fallbackWithApp.contains("\u{2014}"))
    }

    @Test func noTokenFallsBack() async throws {
        let r = try rig(token: nil)
        defer { clean(r) }
        expectFallback(r, await run(r))
        #expect(r.server.listCount == 0)
    }

    @Test func expiredOrUndatedTokenFallsBack() async throws {
        let expired = try rig(expiryDays: -1)
        let undated = try rig(expiryDays: nil)
        defer { clean(expired); clean(undated) }
        expectFallback(expired, await run(expired))
        expectFallback(undated, await run(undated))
        #expect(expired.server.listCount == 0)
    }

    @Test func serverNotRunningFallsBack() async throws {
        let none = try rig(serverOrigin: nil)
        defer { clean(none) }
        expectFallback(none, await run(none))
        #expect(none.server.listCount == 0)
    }

    @Test func aForeignOriginInTheServerFileIsRefusedWithNoCall() async throws {
        let r = try rig(serverOrigin: "http://198.51.100.7:3773")
        defer { clean(r) }
        expectFallback(r, await run(r))
        #expect(r.server.listCount == 0)
        #expect(r.server.created.isEmpty)
    }

    @Test func eachFailedServerStepFallsBack() async throws {
        let listFails = try rig(), createFails = try rig(), launchFails = try rig()
        defer { clean(listFails); clean(createFails); clean(launchFails) }
        listFails.server.listError = T3Error.http(401)
        createFails.server.createError = T3Error.http(500)
        launchFails.server.launchError = T3Error.rejected("nope")
        expectFallback(listFails, await run(listFails))
        expectFallback(createFails, await run(createFails))
        expectFallback(launchFails, await run(launchFails))
    }

    @Test func noCommandAndNoServerGivesTheOtherLine() async throws {
        let r = try rig(serverOrigin: nil, withCLI: false)
        defer { clean(r) }
        let result = await run(r)
        #expect(result == .failed(T3Launcher.fallbackNoApp, copyPrompt: true))
        #expect(r.runner.calls.isEmpty)
    }

    @Test func fallbackWhenTheAppCommandAlsoFailsSaysToPaste() async throws {
        let r = try rig(token: nil, appWorks: false)
        defer { clean(r) }
        #expect(await run(r) == .failed(T3Launcher.fallbackNoApp, copyPrompt: true))
    }
}

// MARK: - Start menu

@MainActor
struct T3StartMenuTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let file = URL(fileURLWithPath: "/Users/me/waggle/docs/My PRD.md")

    private func model(
        app: FakeT3App = FakeT3App(), secrets: FakeSecrets = FakeSecrets(), meta: FakeMeta = FakeMeta(),
        home: URL, server: FakeServer = FakeServer(), runner: FakeCLI = FakeCLI(), bin: URL,
        board: NSPasteboard = NSPasteboard(name: NSPasteboard.Name("knock-test-\(UUID().uuidString)")),
        store: LaunchTargetStoring? = nil
    ) -> LaunchHarness {
        let m = LaunchHarness(
            fileURL: file, launcher: NoTerminalT3(),
            resolvePath: { LoginShellPathResolution(path: bin.path, shellSucceeded: true) }, pasteboard: board,
            opener: app, launchTargetStore: store ?? MemoryTargetStore(), sleep: { _ in }, cliRunner: runner,
            homeDirectory: home.path, t3Secrets: secrets, t3Meta: meta, t3Server: server, environment: [:],
            clock: { [now] in now })
        m.folder = URL(fileURLWithPath: "/Users/me/waggle")
        return m
    }

    @Test func rowsAreNamedAndOrderedAfterConductor() {
        #expect(Array(LaunchTarget.allCases.suffix(2)) == [.claudeT3, .codexT3])
        #expect(LaunchTarget.claudeT3.agentName == "Claude Code")
        #expect(LaunchTarget.codexT3.agentName == "Codex")
        #expect(LaunchTarget.claudeT3.whereLabel == "in T3 Code")
        #expect(LaunchTarget.codexT3.whereLabel == "in T3 Code")
        #expect(LaunchTarget.claudeT3.mainLabel == "Start in T3 Code")
        #expect(LaunchTarget.codexT3.metaLine(folder: "waggle").contains("Codex"))
    }

    @Test func eachBlockedRowShowsItsOwnReason() async throws {
        let bin = try makeBin(), home = try makeHome()
        defer { for d in [bin, home] { try? FileManager.default.removeItem(at: d) } }
        // Not on this Mac.
        let noApp = FakeT3App()
        noApp.installed = false
        let a = model(app: noApp, home: home, bin: bin)
        await a.loadAvailability()
        #expect(a.availability.unavailableText(.claudeT3) == "Not on this Mac")
        #expect(a.availability.unavailableText(.codexT3) == "Not on this Mac")
        // Not connected.
        let b = model(home: home, bin: bin)
        await b.loadAvailability()
        #expect(b.availability.unavailableText(.claudeT3) == "Connect T3 Code in Settings")
        // Expired.
        let c = model(secrets: FakeSecrets("t"), meta: FakeMeta(expiry: now.addingTimeInterval(-5)), home: home, bin: bin)
        await c.loadAvailability()
        #expect(c.availability.unavailableText(.codexT3) == "Connect T3 Code in Settings")
        // Server not running.
        let off = try makeHome(origin: nil)
        defer { try? FileManager.default.removeItem(at: off) }
        let d = model(secrets: FakeSecrets("t"), meta: FakeMeta(expiry: now.addingTimeInterval(86_400)), home: off, bin: bin)
        await d.loadAvailability()
        #expect(d.availability.unavailableText(.claudeT3) == "Open T3 Code first")
        // Ready.
        let e = model(secrets: FakeSecrets("t"), meta: FakeMeta(expiry: now.addingTimeInterval(86_400)), home: home, bin: bin)
        await e.loadAvailability()
        #expect(e.availability.isAvailable(.claudeT3))
        #expect(e.availability.unavailableText(.claudeT3) == nil)
        e.chooseLaunchTarget(.codexT3)
        #expect(e.launchTarget == .codexT3)
    }

    @Test func anUnscopedCommandKeepsTheRowsUsableForOpenAndPaste() async throws {
        let bin = try makeBin(), home = try makeHome(origin: nil)
        defer { for d in [bin, home] { try? FileManager.default.removeItem(at: d) } }
        let runner = FakeCLI()
        runner.stub("auth session issue --help", ok("Options: --ttl"))
        let board = NSPasteboard(name: NSPasteboard.Name("knock-test-\(UUID().uuidString)"))
        let server = FakeServer()
        runner.stub("app", ok())
        let m = model(home: home, server: server, runner: runner, bin: bin, board: board, store: MemoryTargetStore(.claudeT3))
        await m.loadAvailability()
        #expect(m.availability.isAvailable(.claudeT3))
        #expect(m.availability.isAvailable(.codexT3))
        await m.submit()
        #expect(m.errorText == T3Launcher.pasteOnly)
        #expect(board.string(forType: .string) == m.prompt)
        #expect(server.listCount == 0)
    }

    @Test func aBlockedRowCannotBePicked() async throws {
        let bin = try makeBin(), home = try makeHome()
        defer { for d in [bin, home] { try? FileManager.default.removeItem(at: d) } }
        let m = model(home: home, bin: bin)
        await m.loadAvailability()
        m.chooseLaunchTarget(.claudeT3)
        #expect(m.launchTarget != .claudeT3)
    }

    @Test func startSendsThePromptAndFinishes() async throws {
        let bin = try makeBin(), home = try makeHome()
        defer { for d in [bin, home] { try? FileManager.default.removeItem(at: d) } }
        let server = FakeServer(), runner = FakeCLI()
        runner.stub("app", ok())
        let board = NSPasteboard(name: NSPasteboard.Name("knock-test-\(UUID().uuidString)"))
        let store = MemoryTargetStore(.codexT3)
        let m = model(secrets: FakeSecrets("tok"), meta: FakeMeta(expiry: now.addingTimeInterval(86_400)), home: home, server: server, runner: runner, bin: bin, board: board, store: store)
        await m.loadAvailability()
        var finished = false
        m.onFinish = { finished = true }
        await m.submit()
        #expect(finished)
        let launch = try #require(server.launched.first)
        #expect(launch.request.agent.instanceID == "codex")
        #expect(launch.request.prompt == m.prompt)
        #expect(m.errorText == nil)
        #expect(board.string(forType: .string) == nil)
    }

    @Test func aFailedStartCopiesThePromptAndStaysOpenWithOneLine() async throws {
        let bin = try makeBin(), home = try makeHome()
        defer { for d in [bin, home] { try? FileManager.default.removeItem(at: d) } }
        let server = FakeServer(), runner = FakeCLI()
        server.launchError = T3Error.http(500)
        runner.stub("app", ok())
        let board = NSPasteboard(name: NSPasteboard.Name("knock-test-\(UUID().uuidString)"))
        let m = model(secrets: FakeSecrets("tok"), meta: FakeMeta(expiry: now.addingTimeInterval(86_400)), home: home, server: server, runner: runner, bin: bin, board: board, store: MemoryTargetStore(.claudeT3))
        await m.loadAvailability()
        var finished = false
        m.onFinish = { finished = true }
        await m.submit()
        #expect(!finished)
        #expect(m.errorText == T3Launcher.fallbackWithApp)
        #expect(board.string(forType: .string) == m.prompt)
    }
}

private final class MemoryTargetStore: LaunchTargetStoring, @unchecked Sendable {
    private var stored: LaunchTarget?
    init(_ initial: LaunchTarget? = nil) { stored = initial }
    func load() -> LaunchTarget? { stored }
    func save(_ target: LaunchTarget) { stored = target }
}

private struct NoTerminalT3: TerminalLaunching { func launch(script: String) throws {} }
