import Foundation

/// HAIL-164: adds and removes Waggle's one `mcpServers.waggle` entry in the Claude
/// desktop app's `claude_desktop_config.json` (rules from HAIL-159 option A).
/// Nothing here runs until the person presses Connect or Remove and confirms.
/// The file URL is injected, so tests use a temp directory and never the real file.
struct ClaudeDesktopConfig {
    enum ConfigError: Error, Equatable {
        /// The file exists but is not a JSON object (or `mcpServers` is not one).
        case unreadable
        /// The Knock binary could not be found, so there is no command to write.
        case noBinary
        case writeFailed
    }

    enum Status: Equatable {
        case notConnected
        case connected
        /// The file exists but cannot be parsed; nothing is changed.
        case unreadable
    }

    static let serverName = "waggle"
    /// HAIL-176: the entry name before the rename. Only used while `LegacyNames.aliasesEnabled`.
    static let legacyServerName = "knock"
    static let displayPath = "~/Library/Application Support/Claude/claude_desktop_config.json"

    let fileURL: URL
    var fileManager: FileManager = .default

    /// The real location under `home` (the `HOME` variable wins, so a test copy of the app can be pointed at a temp HOME).
    static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> ClaudeDesktopConfig {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return ClaudeDesktopConfig(fileURL: URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"))
    }

    var backupURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent(fileURL.lastPathComponent + ".knock-backup") }

    // MARK: - Status

    /// Connected = the entry is there and its command path exists.
    func status() -> Status {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .notConnected }
        guard let root = try? readRoot() else { return .unreadable }
        guard let servers = root["mcpServers"] as? [String: Any],
              let entry = servers[Self.serverName] as? [String: Any],
              let command = entry["command"] as? String,
              fileManager.fileExists(atPath: command)
        else { return .notConnected }
        return .connected
    }

    // MARK: - Changes

    /// Merges only `mcpServers.waggle`. A missing file is created. An unreadable file is left alone.
    /// An old `knock` entry that is clearly ours goes away in the same write, so Claude does not run two.
    func add(binaryPath: String) throws {
        var root = try readRoot()
        var servers = try serversObject(in: root)
        servers[Self.serverName] = [
            "command": binaryPath,
            "args": ["mcp"],
            "env": ["KNOCK_RUNTIME": "claude"],
        ] as [String: Any]
        if LegacyNames.aliasesEnabled, let legacy = servers[Self.legacyServerName] as? [String: Any], Self.isClearlyOurs(legacy) {
            servers.removeValue(forKey: Self.legacyServerName)
        }
        root["mcpServers"] = servers
        try backUp()
        try write(root)
    }

    /// Deletes only `mcpServers.waggle` (and an old entry of ours named `knock`). Does nothing when
    /// the file or the entries are not there.
    func remove() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        var root = try readRoot()
        var servers = try serversObject(in: root)
        var removed = servers.removeValue(forKey: Self.serverName) != nil
        if LegacyNames.aliasesEnabled, let legacy = servers[Self.legacyServerName] as? [String: Any], Self.isClearlyOurs(legacy) {
            servers.removeValue(forKey: Self.legacyServerName)
            removed = true
        }
        guard removed else { return }
        root["mcpServers"] = servers
        try backUp()
        try write(root)
    }

    // MARK: - HAIL-176 migration

    enum MigrationOutcome: Equatable {
        /// No file, or no old `knock` entry.
        case nothingToDo
        /// The old entry became `waggle`, with the new binary path.
        case moved
        /// `waggle` was there already and the old entry was ours: it was dropped.
        case droppedLegacy
        /// The old entry is not clearly ours (another program), so it stays untouched.
        case keptForeignEntry
    }

    /// First launch after the rename: moves `mcpServers.knock` to `mcpServers.waggle` with the
    /// bundled `waggle` binary, keeping the entry's other keys (args, env). Idempotent. If both exist
    /// the `waggle` one wins and the `knock` one is dropped only when it is clearly ours. The first
    /// backup is kept, as for every other change. An unreadable file throws and is not changed.
    @discardableResult
    func migrateLegacyEntry(binaryPath: String?) throws -> MigrationOutcome {
        guard LegacyNames.aliasesEnabled, fileManager.fileExists(atPath: fileURL.path) else { return .nothingToDo }
        var root = try readRoot()
        var servers = try serversObject(in: root)
        guard let legacy = servers[Self.legacyServerName] as? [String: Any] else { return .nothingToDo }
        let outcome: MigrationOutcome
        if servers[Self.serverName] != nil {
            guard Self.isClearlyOurs(legacy) else { return .keptForeignEntry }
            outcome = .droppedLegacy
        } else {
            guard Self.looksLikeOurs(legacy) else { return .keptForeignEntry }
            guard let binaryPath, !binaryPath.isEmpty else { throw ConfigError.noBinary }
            var entry = legacy
            entry["command"] = binaryPath
            servers[Self.serverName] = entry
            outcome = .moved
        }
        servers.removeValue(forKey: Self.legacyServerName)
        root["mcpServers"] = servers
        try backUp()
        try write(root)
        return outcome
    }

    enum RepointOutcome: Equatable {
        case nothingToDo
        case repointed
    }

    /// HAIL-180: after the app moved (or was renamed by hand) the entry's command can name a
    /// bundle that is gone. Rewrites `mcpServers.waggle.command` to `binaryPath` only when the
    /// command ends in `Resources/waggle` or `Resources/knock` and the file no longer exists.
    /// Other keys stay. The first backup is kept. An unreadable file throws and is not changed.
    @discardableResult
    func repointBundledCommand(to binaryPath: String) throws -> RepointOutcome {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .nothingToDo }
        var root = try readRoot()
        var servers = try serversObject(in: root)
        guard var entry = servers[Self.serverName] as? [String: Any],
              Self.isClearlyOurs(entry),
              let command = entry["command"] as? String,
              command != binaryPath,
              !fileManager.fileExists(atPath: command)
        else { return .nothingToDo }
        entry["command"] = binaryPath
        servers[Self.serverName] = entry
        root["mcpServers"] = servers
        try backUp()
        try write(root)
        return .repointed
    }

    /// The command path ends in `Resources/knock` or `Resources/waggle`: the bundled binary.
    static func isClearlyOurs(_ entry: [String: Any]) -> Bool {
        guard let command = entry["command"] as? String else { return false }
        return command.hasSuffix("/Resources/knock") || command.hasSuffix("/Resources/waggle")
    }

    /// Looser, for a move: the program is called `knock` or `waggle` (a CLI on PATH counts).
    static func looksLikeOurs(_ entry: [String: Any]) -> Bool {
        guard let command = entry["command"] as? String else { return false }
        return ["knock", "waggle"].contains((command as NSString).lastPathComponent)
    }

    // MARK: - File access

    /// `[:]` for a missing file. Throws `.unreadable` for anything that is not a JSON object.
    private func readRoot() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [:] }
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { throw ConfigError.unreadable }
        return root
    }

    private func serversObject(in root: [String: Any]) throws -> [String: Any] {
        guard let value = root["mcpServers"] else { return [:] }
        guard let servers = value as? [String: Any] else { throw ConfigError.unreadable }
        return servers
    }

    /// Keeps the first backup: the file as it was before Knock ever changed it. A later add or
    /// remove never overwrites it, so the person can always go back to their own original.
    private func backUp() throws {
        guard fileManager.fileExists(atPath: fileURL.path), !fileManager.fileExists(atPath: backupURL.path) else { return }
        do {
            try fileManager.copyItem(at: fileURL, to: backupURL)
        } catch {
            throw ConfigError.writeFailed
        }
    }

    private func write(_ root: [String: Any]) throws {
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw ConfigError.writeFailed
        }
    }
}
