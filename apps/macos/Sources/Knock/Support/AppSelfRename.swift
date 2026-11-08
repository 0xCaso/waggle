import AppKit
import Foundation

/// HAIL-180: Sparkle keeps the `Knock.app` folder on update, so Finder, Spotlight and Launchpad
/// still say "Knock". A release build that runs from `Knock.app` moves itself to `Waggle.app` in
/// the same folder, starts the new copy and quits. Any failed condition keeps the app running
/// where it is. Nothing here blocks the app: every outcome is logged to `migration.log`.
enum AppSelfRename {
    static let oldName = "Knock.app"
    static let newName = "Waggle.app"
    static let e2eBundleIdentifier = "dev.limone.knock.e2e"

    enum Decision: Equatable {
        case move(from: URL, to: URL)
        case skip(reason: String)
    }

    /// The pure decision. Every condition of the brief is one `skip` reason.
    static func decide(
        bundleURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Decision {
        if environment["XCTestConfigurationFilePath"] != nil { return .skip(reason: "test run") }
        // The update e2e always runs with a temp KNOCK_HOME. It sets KNOCK_E2E_SELF_RENAME=1 in the
        // test bundle's LSEnvironment, and only the e2e bundle id honours it: a release never does.
        let e2e = environment["KNOCK_E2E_SELF_RENAME"] == "1" && bundleIdentifier == e2eBundleIdentifier
        if let home = environment["KNOCK_HOME"], !home.isEmpty, !e2e { return .skip(reason: "KNOCK_HOME is set") }
        if let id = bundleIdentifier, id.hasSuffix(".dev") { return .skip(reason: "dev build") }
        guard bundleURL.lastPathComponent == oldName else { return .skip(reason: "bundle is not named \(oldName)") }
        let parent = bundleURL.deletingLastPathComponent()
        let target = parent.appendingPathComponent(newName, isDirectory: true)
        // `attributesOfItem` does not follow a link, so a dangling `Waggle.app` link counts as present.
        if (try? fileManager.attributesOfItem(atPath: target.path)) != nil {
            return .skip(reason: "\(newName) already exists in \(parent.path)")
        }
        guard fileManager.isWritableFile(atPath: parent.path) else {
            return .skip(reason: "\(parent.path) is not writable")
        }
        return .move(from: bundleURL, to: target)
    }

    /// Moves the bundle. Returns the new URL, or nil (and a log line) when the move failed.
    static func move(
        from: URL, to: URL,
        fileManager: FileManager = .default,
        log: (String) -> Void = { LaunchMigrationLog.append($0) }
    ) -> URL? {
        do {
            try fileManager.moveItem(at: from, to: to)
            log("selfRename moved \(from.path) -> \(to.path)")
            return to
        } catch {
            log("selfRename failed error=\(error)")
            return nil
        }
    }

    /// Runs at launch, before the plugin refresh. Returns true when this process is about to quit
    /// because the new copy takes over.
    @MainActor
    @discardableResult
    static func runAtLaunch(
        decision: Decision = decide(),
        relaunch: @MainActor (URL, @escaping @Sendable () -> Void) -> Void = AppSelfRename.relaunchAndQuit,
        log: @escaping @Sendable (String) -> Void = { LaunchMigrationLog.append($0) }
    ) -> Bool {
        switch decision {
        case .skip(let reason):
            // Only a Knock.app that stays is worth a line: a normal Waggle.app launch stays quiet.
            if reason != "bundle is not named \(oldName)", reason != "test run" { log("selfRename skipped: \(reason)") }
            return false
        case .move(let from, let to):
            guard let moved = move(from: from, to: to, log: log) else { return false }
            relaunch(moved) { log("selfRename relaunch failed: staying in this process") }
            return true
        }
    }

    /// Starts a new instance of the moved app, then quits this one. If the new instance does
    /// not start, this process keeps running (from the moved folder) and `onFailure` runs.
    @MainActor
    static func relaunchAndQuit(_ url: URL, onFailure: @escaping @Sendable () -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            Task { @MainActor in
                if error == nil { NSApp.terminate(nil) } else { onFailure() }
            }
        }
    }
}

/// HAIL-180: after a move (or a rename by hand) the old bundle path is gone. These repair the
/// two things outside the plugin refresh that still name it: the Claude app entry and the
/// `~/.local/bin` links. Both touch only what clearly points at a missing Waggle bundle.
enum BundlePathRepair {
    /// The `~/.local/bin` link names and the bundled binary each one should reach.
    static let linkNames = ["waggle", "knock"]

    /// Re-points `~/.local/bin/waggle` and `~/.local/bin/knock` when they are symlinks into a
    /// `Knock.app`/`Waggle.app` bundle whose binary no longer exists. A regular file, a link
    /// elsewhere and a link to a binary that still exists stay as they are.
    /// Returns the names that changed.
    @discardableResult
    static func repointLinks(
        home: URL, resources: URL, fileManager: FileManager = .default
    ) -> [String] {
        let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
        var changed: [String] = []
        for name in linkNames {
            let link = bin.appendingPathComponent(name)
            guard let raw = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else { continue }
            let old = raw.hasPrefix("/") ? raw : bin.appendingPathComponent(raw).standardizedFileURL.path
            guard isBundledBinaryPath(old), !fileManager.fileExists(atPath: old) else { continue }
            let target = [resources.appendingPathComponent(name), resources.appendingPathComponent("waggle")]
                .first { fileManager.isExecutableFile(atPath: $0.path) }
            guard let target else { continue }
            do {
                try fileManager.removeItem(at: link)
                try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
                changed.append(name)
            } catch {
                continue
            }
        }
        return changed
    }

    /// `…/Knock.app/Contents/Resources/knock` or the `Waggle.app` / `waggle` spellings.
    static func isBundledBinaryPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 4 else { return false }
        let tail = parts.suffix(4)
        let t = Array(tail)
        return ["Knock.app", "Waggle.app"].contains(t[0]) && t[1] == "Contents" && t[2] == "Resources"
            && ["knock", "waggle"].contains(t[3])
    }

    /// A test, an evidence run (set KNOCK_HOME) or a dev build never touches the real home.
    static func shouldRun(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        if let home = environment["KNOCK_HOME"], !home.isEmpty { return false }
        if environment["XCTestConfigurationFilePath"] != nil { return false }
        if let id = bundleIdentifier, id.hasSuffix(".dev") { return false }
        return true
    }

    /// Runs both repairs once per launch. Never throws.
    @MainActor
    static func runAtLaunch(
        config: ClaudeDesktopConfig, home: URL, binaryPath: URL?,
        log: (String) -> Void = { LaunchMigrationLog.append($0) }
    ) {
        guard let binaryPath else { return }
        do {
            let outcome = try config.repointBundledCommand(to: binaryPath.path)
            if outcome != .nothingToDo { log("claudeAppRepoint \(outcome)") }
        } catch {
            log("claudeAppRepoint failed error=\(error)")
        }
        let links = repointLinks(home: home, resources: binaryPath.deletingLastPathComponent())
        if !links.isEmpty { log("linkRepoint \(links.joined(separator: ","))") }
    }
}
