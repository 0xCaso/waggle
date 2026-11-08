import Foundation

/// Decides whether the app must replace the running daemon (HAIL-27). The app
/// owns its daemon: it restarts whenever the running daemon's version OR binary
/// path differs from the app's own - not only when the app is newer (the
/// KNOCK-21 rule this replaces). A missing `exec_path` (an older daemon) also
/// differs, so the app replaces it.
enum DaemonEnforcement {
    static func needsRestart(
        appVersion: String,
        appBinaryPath: String,
        status: ServiceStatus
    ) -> Bool {
        guard status.version == appVersion, let execPath = status.execPath else { return true }
        // HAIL-176: `Resources/knock` is a symlink to `Resources/waggle`, so the daemon may have been
        // started through either name. Compare real files, not names.
        return ServiceControl.realPath(execPath) != ServiceControl.realPath(appBinaryPath)
    }
}
