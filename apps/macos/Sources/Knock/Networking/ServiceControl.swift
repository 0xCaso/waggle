import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Starts the Waggle daemon on demand instead of a LaunchAgent (docs/SERVICE.md).
/// The app calls this from the M11 "Start service" button and from
/// `KnockClient`'s connect path when the socket is unreachable
/// (docs/design/mvp-values.md §2.14, §M11).
enum ServiceControl {
    /// The `waggle` binary bundled with the app, at `Waggle.app/Contents/Resources/waggle`
    /// (or `Knock.app/...` when a Sparkle update left the bundle at the old path). While the
    /// legacy switch is on, an older bundle that only has `knock` still works. When neither file
    /// exists the `waggle` path is returned, as before.
    static func knockBinaryPath(bundle: Bundle = .main, fileManager: FileManager = .default) -> String {
        guard let resource = bundle.resourceURL else {
            return "/usr/local/bin/waggle"
        }
        let preferred = resource.appendingPathComponent(KnockBinaryLocator.binaryName).path
        if LegacyNames.aliasesEnabled, !fileManager.isExecutableFile(atPath: preferred) {
            let legacy = resource.appendingPathComponent(KnockBinaryLocator.legacyBinaryName).path
            if fileManager.isExecutableFile(atPath: legacy) { return legacy }
        }
        return preferred
    }

    /// The app's own bundled binary with symlinks resolved, for comparison with
    /// the daemon's `service.status.exec_path` (HAIL-27). Uses POSIX
    /// `realpath(3)` so it matches the daemon's own `realpathSync`:
    /// Foundation's `resolvingSymlinksInPath()` leaves `/var` unresolved while
    /// the daemon resolves it to `/private/var`, which would make the two sides
    /// never equal and restart the daemon forever.
    static func resolvedBinaryPath(bundle: Bundle = .main) -> String {
        realPath(knockBinaryPath(bundle: bundle))
    }

    /// POSIX `realpath(3)` of a path, falling back to the unresolved path when
    /// the file does not exist (or cannot be resolved).
    static func realPath(_ path: String) -> String {
        let resolved = path.withCString { cPath -> String? in
            guard let rp = realpath(cPath, nil) else { return nil }
            defer { free(rp) }
            return String(cString: rp)
        }
        return resolved ?? path
    }

    /// `launch` is injectable so tests can assert the exact command without
    /// spawning a real daemon.
    static func startDaemon(launch: (String, [String]) -> Void = defaultLaunch) {
        launch(knockBinaryPath(), ["daemon"])
    }

    /// The same launch as `startDaemon`, and it says whether the process began. The Paused card needs that to
    /// tell a start that failed at once from one that is slow.
    static func launchDaemon() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: knockBinaryPath())
        process.arguments = ["daemon"]
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    private static func defaultLaunch(_ executablePath: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        // Detached by default: the daemon keeps running after the app quits.
        try? process.run()
    }
}
