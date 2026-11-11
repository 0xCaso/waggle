import Testing
import Foundation
@testable import Knock

/// HAIL-180: every test uses a temp directory and a temp config. None touches the real home,
/// the real Applications folder or the real Claude app file.
@MainActor
struct AppSelfRenameTests {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("knock-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func bundle(in parent: URL, name: String = "Knock.app") throws -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        return url
    }

    private func decide(_ url: URL, id: String? = "dev.limone.knock", env: [String: String] = [:]) -> AppSelfRename.Decision {
        AppSelfRename.decide(bundleURL: url, bundleIdentifier: id, environment: env)
    }

    // MARK: decision

    @Test func movesAReleaseKnockApp() throws {
        let dir = try temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let app = try bundle(in: dir)
        #expect(decide(app) == .move(from: app, to: dir.appendingPathComponent("Waggle.app", isDirectory: true)))
    }

    @Test func staysWhenAlreadyNamedWaggle() throws {
        let dir = try temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let app = try bundle(in: dir, name: "Waggle.app")
        guard case .skip = decide(app) else { Issue.record("expected skip"); return }
    }

    @Test func staysWhenWaggleAppExists() throws {
        let dir = try temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let app = try bundle(in: dir)
        _ = try bundle(in: dir, name: "Waggle.app")
        guard case .skip(let reason) = decide(app) else { Issue.record("expected skip"); return }
        #expect(reason.contains("already exists"))
    }

    @Test func staysWhenWaggleAppIsADanglingLink() throws {
        let dir = try temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let app = try bundle(in: dir)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("Waggle.app").path, withDestinationPath: "/nowhere")
        guard case .skip = decide(app) else { Issue.record("expected skip"); return }
    }

    @Test func staysWhenParentIsNotWritable() throws {
        let dir = try temp(); defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let app = try bundle(in: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        guard case .skip(let reason) = decide(app) else { Issue.record("expected skip"); return }
        #expect(reason.contains("not writable"))
    }

    @Test func staysForDevTestsAndKnockHome() throws {
        let dir = try temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let app = try bundle(in: dir)
        for (id, env) in [("dev.limone.knock.dev", [:]), ("dev.limone.knock", ["XCTestConfigurationFilePath": "x"]),
                          ("dev.limone.knock", ["KNOCK_HOME": "/tmp/k"])] as [(String, [String: String])] {
            guard case .skip = decide(app, id: id, env: env) else { Issue.record("expected skip for \(id) \(env)"); continue }
        }
    }

    @Test func e2eSwitchOnlyWorksForTheE2EBundleId() throws {
        let dir = try temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let app = try bundle(in: dir)
        let env = ["KNOCK_HOME": "/tmp/k", "KNOCK_E2E_SELF_RENAME": "1"]
        guard case .move = decide(app, id: "dev.limone.knock.e2e", env: env) else { Issue.record("e2e should move"); return }
        guard case .skip = decide(app, id: "dev.limone.knock", env: env) else { Issue.record("release must ignore the switch"); return }
    }

    // MARK: move

    @Test func moveRenamesAndASecondLaunchDoesNothing() throws {
        let dir = try temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let app = try bundle(in: dir)
        var relaunched: URL?
        let quit = AppSelfRename.runAtLaunch(decision: decide(app), relaunch: { url, _ in relaunched = url }, log: { _ in })
        let newURL = dir.appendingPathComponent("Waggle.app", isDirectory: true)
        #expect(quit)
        #expect(relaunched == newURL)
        #expect(FileManager.default.fileExists(atPath: newURL.path))
        #expect(!FileManager.default.fileExists(atPath: app.path))
        // Second launch from Waggle.app.
        relaunched = nil
        let again = AppSelfRename.runAtLaunch(decision: decide(newURL), relaunch: { url, _ in relaunched = url }, log: { _ in })
        #expect(!again && relaunched == nil)
    }

    @Test func failedMoveKeepsRunningAndLogs() throws {
        let dir = try temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("Knock.app", isDirectory: true)
        let target = dir.appendingPathComponent("Waggle.app", isDirectory: true)
        nonisolated(unsafe) var lines: [String] = []
        let quit = AppSelfRename.runAtLaunch(
            decision: .move(from: missing, to: target), relaunch: { _, _ in Issue.record("must not relaunch") },
            log: { lines.append($0) })
        #expect(!quit)
        #expect(lines.contains { $0.hasPrefix("selfRename failed") })
    }

    // MARK: re-pointing

    private func config(in root: URL) -> ClaudeDesktopConfig {
        ClaudeDesktopConfig(fileURL: root.appendingPathComponent("Claude/claude_desktop_config.json"))
    }

    private func write(_ json: String, to config: ClaudeDesktopConfig) throws {
        try FileManager.default.createDirectory(at: config.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: config.fileURL, atomically: true, encoding: .utf8)
    }

    private func command(_ config: ClaudeDesktopConfig, _ name: String = "waggle") throws -> String? {
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: config.fileURL)) as? [String: Any])
        return ((root["mcpServers"] as? [String: Any])?[name] as? [String: Any])?["command"] as? String
    }

    @Test func claudeEntryIntoAMissingBundleIsRewrittenWithBackup() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let c = config(in: root)
        let original = #"{"mcpServers":{"waggle":{"command":"/gone/Knock.app/Contents/Resources/knock","args":["mcp"],"env":{"A":"b"}}}}"#
        try write(original, to: c)
        let outcome = try c.repointBundledCommand(to: "/new/Waggle.app/Contents/Resources/waggle")
        #expect(outcome == .repointed)
        #expect(try command(c) == "/new/Waggle.app/Contents/Resources/waggle")
        let entry = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: c.fileURL)) as? [String: Any])?["mcpServers"] as? [String: Any])
        #expect(((entry["waggle"] as? [String: Any])?["args"] as? [String]) == ["mcp"])
        #expect(try String(contentsOf: c.backupURL, encoding: .utf8) == original)
        // Idempotent.
        #expect(try c.repointBundledCommand(to: "/new/Waggle.app/Contents/Resources/waggle") == .nothingToDo)
    }

    @Test func claudeEntryKeepsFirstBackup() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let c = config(in: root)
        try write(#"{"mcpServers":{"waggle":{"command":"/gone/Knock.app/Contents/Resources/knock"}}}"#, to: c)
        try "first".write(to: c.backupURL, atomically: true, encoding: .utf8)
        try c.repointBundledCommand(to: "/new/Resources/waggle")
        #expect(try String(contentsOf: c.backupURL, encoding: .utf8) == "first")
    }

    @Test func claudeEntryThatExistsOrIsForeignIsLeftAlone() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let c = config(in: root)
        let live = try bundle(in: root).appendingPathComponent("Contents/Resources/knock")
        try Data().write(to: live)
        try write(#"{"mcpServers":{"waggle":{"command":"\#(live.path)"}}}"#, to: c)
        #expect(try c.repointBundledCommand(to: "/new/Resources/waggle") == .nothingToDo)
        try write(#"{"mcpServers":{"waggle":{"command":"/gone/other-tool"}}}"#, to: c)
        #expect(try c.repointBundledCommand(to: "/new/Resources/waggle") == .nothingToDo)
        #expect(try command(c) == "/gone/other-tool")
        #expect(!FileManager.default.fileExists(atPath: c.backupURL.path))
    }

    @Test func claudeFileMissingOrUnreadable() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let c = config(in: root)
        #expect(try c.repointBundledCommand(to: "/new/Resources/waggle") == .nothingToDo)
        try write("not json", to: c)
        #expect(throws: ClaudeDesktopConfig.ConfigError.unreadable) { try c.repointBundledCommand(to: "/new/Resources/waggle") }
    }

    @Test func linksIntoAMissingBundleAreRepointed() throws {
        let home = try temp(); defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let resources = try bundle(in: home, name: "Waggle.app").appendingPathComponent("Contents/Resources")
        let newBinary = resources.appendingPathComponent("waggle")
        try "#!/bin/sh\n".write(to: newBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newBinary.path)
        for name in ["waggle", "knock"] {
            try FileManager.default.createSymbolicLink(
                atPath: bin.appendingPathComponent(name).path,
                withDestinationPath: "/gone/Knock.app/Contents/Resources/\(name)")
        }
        let changed = BundlePathRepair.repointLinks(home: home, resources: resources)
        #expect(Set(changed) == ["waggle", "knock"])
        for name in ["waggle", "knock"] {
            let dest = try FileManager.default.destinationOfSymbolicLink(atPath: bin.appendingPathComponent(name).path)
            #expect(dest == newBinary.path)
        }
        #expect(BundlePathRepair.repointLinks(home: home, resources: resources).isEmpty)
    }

    @Test func regularFilesAndForeignLinksAreNeverTouched() throws {
        let home = try temp(); defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let resources = try bundle(in: home, name: "Waggle.app").appendingPathComponent("Contents/Resources")
        try "#!/bin/sh\n".write(to: resources.appendingPathComponent("waggle"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: resources.appendingPathComponent("waggle").path)
        try "regular".write(to: bin.appendingPathComponent("knock"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("waggle").path, withDestinationPath: "/gone/elsewhere/waggle")
        #expect(BundlePathRepair.repointLinks(home: home, resources: resources).isEmpty)
        #expect(try String(contentsOf: bin.appendingPathComponent("knock"), encoding: .utf8) == "regular")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: bin.appendingPathComponent("waggle").path) == "/gone/elsewhere/waggle")
    }

    @Test func linkToAnExistingBundleStays() throws {
        let home = try temp(); defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let other = try bundle(in: home, name: "Knock.app").appendingPathComponent("Contents/Resources/waggle")
        try "x".write(to: other, atomically: true, encoding: .utf8)
        let resources = try bundle(in: home, name: "Waggle.app").appendingPathComponent("Contents/Resources")
        try "x".write(to: resources.appendingPathComponent("waggle"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: resources.appendingPathComponent("waggle").path)
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("waggle").path, withDestinationPath: other.path)
        #expect(BundlePathRepair.repointLinks(home: home, resources: resources).isEmpty)
    }

    // MARK: header

    @Test func headerLockupStartsAtTheLeftEdgeUnderTheTrafficLights() {
        #expect(QueueHeaderLayout.leadingInset(trafficLightsMaxX: nil) == 16)
        #expect(QueueHeaderLayout.leadingInset(trafficLightsMaxX: 68) == 16)
        #expect(QueueHeaderLayout.topInset(trafficLightsMaxX: 68) == 40)
        #expect(QueueHeaderLayout.topInset(trafficLightsMaxX: nil) == 16)
    }
}
