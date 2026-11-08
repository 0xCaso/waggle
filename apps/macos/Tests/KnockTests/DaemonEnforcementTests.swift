import Testing
@testable import Knock

/// The app enforces its own daemon (HAIL-27): it restarts the running daemon
/// whenever the daemon's version or binary path differs from the app's own.
/// These cover the four required cases - same, older, newer, different path -
/// plus a missing `exec_path` from an older daemon.
struct DaemonEnforcementTests {
    private static let appVersion = "0.1.1"
    private static let appPath = "/Apps/Waggle.app/Contents/Resources/knock"

    private func status(version: String, execPath: String?) -> ServiceStatus {
        ServiceStatus(
            version: version,
            dataRoot: "/tmp/knock",
            sessionsLive: 0,
            casesOpen: 0,
            execPath: execPath
        )
    }

    @Test func sameVersionAndPathNeedsNoRestart() {
        let s = status(version: "0.1.1", execPath: Self.appPath)
        #expect(!DaemonEnforcement.needsRestart(appVersion: Self.appVersion, appBinaryPath: Self.appPath, status: s))
    }

    @Test func olderDaemonNeedsRestart() {
        let s = status(version: "0.1.0", execPath: Self.appPath)
        #expect(DaemonEnforcement.needsRestart(appVersion: Self.appVersion, appBinaryPath: Self.appPath, status: s))
    }

    @Test func newerDaemonNeedsRestart() {
        let s = status(version: "0.1.2", execPath: Self.appPath)
        #expect(DaemonEnforcement.needsRestart(appVersion: Self.appVersion, appBinaryPath: Self.appPath, status: s))
    }

    @Test func differentPathNeedsRestart() {
        let sparkleCache = "/Caches/org.sparkle-project.Sparkle/Installation/x/Waggle.app/Contents/Resources/knock"
        let s = status(version: "0.1.1", execPath: sparkleCache)
        #expect(DaemonEnforcement.needsRestart(appVersion: Self.appVersion, appBinaryPath: Self.appPath, status: s))
    }

    @Test func missingExecPathNeedsRestart() {
        let s = status(version: "0.1.1", execPath: nil)
        #expect(DaemonEnforcement.needsRestart(appVersion: Self.appVersion, appBinaryPath: Self.appPath, status: s))
    }
}
