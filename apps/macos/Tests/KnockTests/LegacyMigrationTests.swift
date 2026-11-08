import Testing
import Foundation
@testable import Knock

/// HAIL-176: the first launch after the rename. Every test uses temp directories only.
/// None touches the real Claude app folder, the real logs or a real Claude Code.
@MainActor
struct LegacyMigrationTests {
    private func makeConfig() throws -> (ClaudeDesktopConfig, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("waggle-migrate-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("Library/Application Support/Claude")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (ClaudeDesktopConfig(fileURL: dir.appendingPathComponent("claude_desktop_config.json")), root)
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private let oldCommand = "/Applications/Knock.app/Contents/Resources/knock"
    private let newCommand = "/Applications/Waggle.app/Contents/Resources/waggle"

    private func oldFile(extraEnv: String = "") -> String {
        """
        {"theme":"dark","mcpServers":{"dayflow":{"command":"/x/dayflow"},"knock":{"command":"\(oldCommand)","args":["mcp"],"env":{"KNOCK_RUNTIME":"claude"\(extraEnv)}}}}
        """
    }

    // MARK: Claude app entry

    @Test func movesTheEntryAndKeepsArgsEnvAndOtherServers() throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }
        try oldFile(extraEnv: #","KEEP":"me""#).write(to: config.fileURL, atomically: true, encoding: .utf8)

        let outcome = try config.migrateLegacyEntry(binaryPath: newCommand)

        #expect(outcome == .moved)
        let result = try json(config.fileURL)
        #expect(result["theme"] as? String == "dark")
        let servers = try #require(result["mcpServers"] as? [String: Any])
        #expect(servers["knock"] == nil)
        #expect((servers["dayflow"] as? [String: Any])?["command"] as? String == "/x/dayflow")
        let waggle = try #require(servers["waggle"] as? [String: Any])
        #expect(waggle["command"] as? String == newCommand)
        #expect(waggle["args"] as? [String] == ["mcp"])
        #expect((waggle["env"] as? [String: String]) == ["KNOCK_RUNTIME": "claude", "KEEP": "me"])
    }

    @Test func aSecondRunChangesNothing() throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }
        try oldFile().write(to: config.fileURL, atomically: true, encoding: .utf8)
        try config.migrateLegacyEntry(binaryPath: newCommand)
        let after = try Data(contentsOf: config.fileURL)

        let outcome = try config.migrateLegacyEntry(binaryPath: newCommand)

        #expect(outcome == .nothingToDo)
        #expect(try Data(contentsOf: config.fileURL) == after)
    }

    @Test func theFirstBackupIsKeptAndNeverOverwritten() throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = oldFile()
        try original.write(to: config.fileURL, atomically: true, encoding: .utf8)
        try Data("first backup".utf8).write(to: config.backupURL)

        try config.migrateLegacyEntry(binaryPath: newCommand)
        #expect(try String(contentsOf: config.backupURL, encoding: .utf8) == "first backup")

        // And with no earlier backup: the backup is the file as it was before the move.
        try FileManager.default.removeItem(at: config.backupURL)
        try original.write(to: config.fileURL, atomically: true, encoding: .utf8)
        try config.migrateLegacyEntry(binaryPath: newCommand)
        #expect(try String(contentsOf: config.backupURL, encoding: .utf8) == original)
    }

    @Test func bothPresentKeepsWaggleAndDropsAnOldEntryThatIsOurs() throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = """
        {"mcpServers":{"knock":{"command":"\(oldCommand)"},"waggle":{"command":"/mine/waggle","args":["mcp"]}}}
        """
        try text.write(to: config.fileURL, atomically: true, encoding: .utf8)

        let outcome = try config.migrateLegacyEntry(binaryPath: newCommand)

        #expect(outcome == .droppedLegacy)
        let servers = try #require(try json(config.fileURL)["mcpServers"] as? [String: Any])
        #expect(servers["knock"] == nil)
        #expect((servers["waggle"] as? [String: Any])?["command"] as? String == "/mine/waggle")
    }

    @Test func bothPresentLeavesAnOldEntryThatIsNotOurs() throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = """
        {"mcpServers":{"knock":{"command":"/usr/bin/node","args":["other.js"]},"waggle":{"command":"/mine/waggle"}}}
        """
        try text.write(to: config.fileURL, atomically: true, encoding: .utf8)

        #expect(try config.migrateLegacyEntry(binaryPath: newCommand) == .keptForeignEntry)
        let servers = try #require(try json(config.fileURL)["mcpServers"] as? [String: Any])
        #expect(servers["knock"] != nil)
        #expect(!FileManager.default.fileExists(atPath: config.backupURL.path))
    }

    @Test func aForeignKnockEntryIsNeverMoved() throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = #"{"mcpServers":{"knock":{"command":"/usr/bin/node"}}}"#
        try text.write(to: config.fileURL, atomically: true, encoding: .utf8)
        #expect(try config.migrateLegacyEntry(binaryPath: newCommand) == .keptForeignEntry)
        #expect(try String(contentsOf: config.fileURL, encoding: .utf8) == text)
    }

    @Test func noFileOrNoOldEntryDoesNothing() throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try config.migrateLegacyEntry(binaryPath: newCommand) == .nothingToDo)
        #expect(!FileManager.default.fileExists(atPath: config.fileURL.path))
        let text = #"{"mcpServers":{"dayflow":{"command":"/x"}}}"#
        try text.write(to: config.fileURL, atomically: true, encoding: .utf8)
        #expect(try config.migrateLegacyEntry(binaryPath: newCommand) == .nothingToDo)
        #expect(try String(contentsOf: config.fileURL, encoding: .utf8) == text)
    }

    @Test func anUnreadableFileFailsAndIsRecordedWithoutBlocking() throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }
        try "{ not json".write(to: config.fileURL, atomically: true, encoding: .utf8)
        let status = LaunchMigrationStatus()
        var lines: [String] = []

        let failure = ClaudeAppMigration.run(config: config, binaryPath: { self.newCommand }, status: status, log: { lines.append($0) })

        #expect(failure == ClaudeAppMigration.failureMessage)
        #expect(status.claudeAppFailure == ClaudeAppMigration.failureMessage)
        #expect(lines.contains { $0.contains("failed") })
        #expect(try String(contentsOf: config.fileURL, encoding: .utf8) == "{ not json")
    }

    @Test func aMissingBinaryFailsOnlyWhenThereIsSomethingToMove() throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }
        let status = LaunchMigrationStatus()
        #expect(ClaudeAppMigration.run(config: config, binaryPath: { nil }, status: status, log: { _ in }) == nil)
        try oldFile().write(to: config.fileURL, atomically: true, encoding: .utf8)
        #expect(ClaudeAppMigration.run(config: config, binaryPath: { nil }, status: status, log: { _ in }) != nil)
        #expect(status.claudeAppFailure != nil)
        // Fixed later: a good run clears the failure.
        #expect(ClaudeAppMigration.run(config: config, binaryPath: { self.newCommand }, status: status, log: { _ in }) == nil)
        #expect(status.claudeAppFailure == nil)
    }

    @Test func theMigrationNeverRunsInATestOrATestCopyOrADevBuild() {
        #expect(!ClaudeAppMigration.shouldRun(environment: ["XCTestConfigurationFilePath": "/x"], bundleIdentifier: "dev.limone.knock"))
        #expect(!ClaudeAppMigration.shouldRun(environment: ["KNOCK_HOME": "/tmp/x"], bundleIdentifier: "dev.limone.knock"))
        #expect(!ClaudeAppMigration.shouldRun(environment: [:], bundleIdentifier: "dev.limone.knock.dev"))
        #expect(ClaudeAppMigration.shouldRun(environment: [:], bundleIdentifier: "dev.limone.knock"))
    }

    @Test func connectingAgainDropsTheOldEntryOfOurs() throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }
        try oldFile().write(to: config.fileURL, atomically: true, encoding: .utf8)
        try config.add(binaryPath: newCommand)
        let servers = try #require(try json(config.fileURL)["mcpServers"] as? [String: Any])
        #expect(servers["knock"] == nil)
        #expect(servers["waggle"] != nil)
        #expect(servers["dayflow"] != nil)
    }

    // MARK: Plugin migration

    private struct FakeRunner: OnboardingCommandRunning {
        let exitCodes: [Int32]
        let calls = CallLog()

        final class CallLog: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [[String]] = []
            func add(_ a: [String]) { lock.lock(); items.append(a); lock.unlock() }
            var all: [[String]] { lock.lock(); defer { lock.unlock() }; return items }
        }

        func run(_ arguments: [String], onLine: @escaping @MainActor (String) -> Void) async -> Int32 {
            calls.add(arguments)
            let index = calls.all.count - 1
            await onLine("ran \(arguments.joined(separator: " "))")
            return exitCodes[min(index, exitCodes.count - 1)]
        }
    }

    final class LogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    @Test func theLaunchRefreshRunsBothRefreshesAndLogsThemEvenWhenOnlyTheLegacyPluginIsInstalled() async {
        // `--refresh` itself moves knock@knock to waggle@waggle (the binary does it), so the app
        // always runs it: there is no version check that could skip the move.
        let runner = FakeRunner(exitCodes: [0, 0])
        let status = LaunchMigrationStatus()
        let log = LogBox()

        await PluginRefresh.refreshBoth(runner: runner, status: status, log: { log.add($0) })

        #expect(runner.calls.all == [["install", "claude", "--refresh"], ["install", "codex", "--refresh"]])
        #expect(status.pluginFailure == nil)
        #expect(log.all.contains { $0.contains("pluginRefresh claude exit=0") })
        #expect(log.all.contains { $0.contains("pluginRefresh codex exit=0") })
    }

    @Test func aFailedRefreshIsRecordedForSettingsAndDoesNotStopTheSecondRun() async {
        let runner = FakeRunner(exitCodes: [1, 0])
        let status = LaunchMigrationStatus()

        await PluginRefresh.refreshBoth(runner: runner, status: status, log: { _ in })

        #expect(runner.calls.all.count == 2)
        #expect(status.pluginFailure == PluginRefresh.claudeFailureMessage)

        await PluginRefresh.refreshBoth(runner: FakeRunner(exitCodes: [0, 0]), status: status, log: { _ in })
        #expect(status.pluginFailure == nil)
    }

    // MARK: Log

    @Test func theMigrationLogAppendsLinesInATempFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("waggle-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        LaunchMigrationLog.append("one", directory: dir)
        LaunchMigrationLog.append("two", directory: dir)
        let text = try String(contentsOf: dir.appendingPathComponent("migration.log"), encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix(" one") && lines[1].hasSuffix(" two"))
    }
}
