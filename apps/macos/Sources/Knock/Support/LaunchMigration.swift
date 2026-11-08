import Foundation

/// HAIL-176: what the first launch after the Knock to Waggle rename did, and what failed.
/// Settings > Agents shows a failure. A failure never blocks the app.
@MainActor
final class LaunchMigrationStatus: ObservableObject {
    static let shared = LaunchMigrationStatus()

    @Published var claudeAppFailure: String?
    @Published var pluginFailure: String?
}

/// One line per event in `migration.log`, next to `update.log`, same timestamp style.
enum LaunchMigrationLog {
    static func append(
        _ line: String,
        directory: URL = UpdaterLogDelegate.logDirectory(),
        now: Date = Date()
    ) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("migration.log")
        let text = "\(ISO8601DateFormatter().string(from: now)) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}

/// Moves the Claude app's `mcpServers.knock` entry to `mcpServers.waggle` once per launch.
enum ClaudeAppMigration {
    static let failureMessage = "Waggle could not move its entry in the Claude app's settings. Press Connect to add it again."

    /// A test, an evidence run (set KNOCK_HOME) or a dev build never touches the real Claude app file.
    static func shouldRun(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        guard LegacyNames.aliasesEnabled else { return false }
        if let home = environment["KNOCK_HOME"], !home.isEmpty { return false }
        if environment["XCTestConfigurationFilePath"] != nil { return false }
        if let id = bundleIdentifier, id.hasSuffix(".dev") { return false }
        return true
    }

    /// Returns the failure text (also stored in `status`), or nil. Never throws.
    @MainActor
    @discardableResult
    static func run(
        config: ClaudeDesktopConfig,
        binaryPath: () -> String?,
        status: LaunchMigrationStatus = .shared,
        log: (String) -> Void = { LaunchMigrationLog.append($0) }
    ) -> String? {
        do {
            let outcome = try config.migrateLegacyEntry(binaryPath: binaryPath())
            log("claudeAppMigration \(outcome)")
            status.claudeAppFailure = nil
            return nil
        } catch {
            log("claudeAppMigration failed error=\(error)")
            status.claudeAppFailure = failureMessage
            return failureMessage
        }
    }
}
