import AppKit
import Sparkle

/// Sparkle 2 auto-updates (KNOCK-21). One standard updater controller serves the
/// app menu and the menu bar extra. `startingUpdater: true` schedules the
/// automatic check on launch; `SUEnableAutomaticChecks` in the bundle's
/// Info.plist pre-approves it, so after that first permission updates
/// download unattended, the update toast asks for a restart, and the update
/// installs on the next quit (or on "Restart now"). Knock never relaunches
/// on its own (HAIL-80).
///
/// A dev or local build embeds no `SUPublicEDKey` (scripts/bundle-app.sh writes
/// it only for a release). Sparkle must not start without a key: an empty key
/// makes it fail and show an alert ("Unable to Check For Updates"). So this
/// type is inert without one, and every "Check for Updates…" affordance is
/// disabled (KnockApp, MenuBarController, SettingsView).
@MainActor
enum Updater {
    /// The controller references its delegate weakly; this static keeps the
    /// logging delegate alive for the app's lifetime (KNOCK-21 amendment).
    private static let logDelegate = UpdaterLogDelegate()

    /// Whether this bundle can check for updates: it carries a non-empty
    /// `SUPublicEDKey` (a release build only).
    static let isAvailable = hasPublicKey(Bundle.main.infoDictionary ?? [:])

    /// True when `info` carries a non-empty `SUPublicEDKey`. A key that is
    /// present but empty (the old dev-build plist) counts as absent.
    nonisolated static func hasPublicKey(_ info: [String: Any]) -> Bool {
        guard let key = info["SUPublicEDKey"] as? String, !key.isEmpty else { return false }
        return true
    }

    static let controller: SPUStandardUpdaterController? = {
        guard isAvailable else { return nil }
        return SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: logDelegate,
            userDriverDelegate: logDelegate
        )
    }()

    static func checkForUpdates() {
        // An update already downloaded and waiting (the toast hook,
        // `willInstallUpdateOnQuit`) pauses Sparkle's cycle, so a new check
        // would do nothing (operator, 29 Sep: "check for updates does
        // nothing"). Bring the toast back instead, with Restart now.
        if UpdateReadyModel.shared.showAgainIfReady() {
            AppActivation.showMainWindow()
            return
        }
        controller?.checkForUpdates(nil)
    }

    /// e2e only: `KNOCK_UPDATE_CHECK_NOW=1` (scripts/update-e2e.sh) forces one
    /// immediate background check at launch so the test does not wait for the
    /// hourly scheduler.
    static func checkNowIfRequested() {
        if ProcessInfo.processInfo.environment["KNOCK_UPDATE_CHECK_NOW"] == "1" {
            controller?.updater.checkForUpdatesInBackground()
        }
    }

    // MARK: Check on every start (WAG-318)

    private static var launchCheckRan = false
    /// True from the start check until Sparkle finishes it. Only then does a
    /// found update open the prompt.
    static var launchProbeActive = false
    /// "Install and restart" was pressed in the prompt. The next downloaded
    /// update installs at once, which is the person's own choice (HAIL-80).
    static var installRequested = false

    /// Runs one check a few seconds after start, once per start, when the
    /// build has a feed key and the setting is on. The check only reads the
    /// feed (`checkForUpdateInformation`): no download, no Sparkle window.
    /// Offline or a failed feed shows nothing and lands in update.log.
    static func scheduleLaunchCheck(delay: TimeInterval = 5) {
        let environment = ProcessInfo.processInfo.environment
        guard LaunchUpdateCheck.shouldRun(
            isAvailable: isAvailable, enabled: LaunchUpdateCheckSettings.isEnabled(),
            alreadyRan: launchCheckRan, scriptedCheck: environment["KNOCK_UPDATE_CHECK_NOW"] == "1")
        else { return }
        launchCheckRan = true
        Task { @MainActor in
            for attempt in 0..<3 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                // Sparkle's own scheduled check may have downloaded an update already.
                // The restart toast then holds it: ask about that one.
                if let ready = UpdateReadyModel.shared.ready {
                    logDelegate.logLine("launchCheck update waiting \(ready.version)")
                    promptForWaitingUpdate(ready)
                    return
                }
                // Or it may be busy with that check; try again shortly.
                guard let updater = controller?.updater, updater.canCheckForUpdates else {
                    logDelegate.logLine("launchCheck busy attempt=\(attempt + 1)")
                    continue
                }
                UpdatePromptModel.shared.startInstall = { requestInstall() }
                launchProbeActive = true
                logDelegate.logLine("launchCheck start")
                updater.checkForUpdateInformation()
                return
            }
        }
    }

    private static func promptForWaitingUpdate(_ ready: UpdateReadyModel.Ready) {
        guard !SkippedUpdateVersion.isSkipped(ready.version) else { return }
        UpdatePromptModel.shared.startInstall = { UpdateReadyModel.shared.restartNow() }
        UpdatePromptModel.shared.present(.init(
            version: ready.version, whatsNew: [ready.headline].compactMap { $0 }))
    }

    /// An update the start check found: open the prompt unless the version is
    /// skipped or another update already waits behind the restart toast.
    static func launchProbeFound(version: String, releaseNotes: String?) {
        guard launchProbeActive else { return }
        launchProbeActive = false
        guard LaunchUpdateCheck.shouldPrompt(
            version: version, skipped: SkippedUpdateVersion.isSkipped(version),
            updateWaiting: UpdateReadyModel.shared.isReady)
        else { return }
        UpdatePromptModel.shared.present(.init(
            version: version, whatsNew: LaunchUpdateCheck.whatsNew(fromReleaseNotes: releaseNotes)))
    }

    /// "Install and restart": download now. `UpdaterLogDelegate.armInstallOnQuit`
    /// installs the finished download at once.
    static func requestInstall() {
        installRequested = true
        controller?.updater.checkForUpdatesInBackground()
    }

    /// The last time Sparkle actually checked, when it has checked at least
    /// once this launch (Settings' Updates page, HAIL-50). `nil` before the
    /// first check, or when updates are unavailable in this build.
    static var lastCheckDate: Date? {
        controller?.updater.lastUpdateCheckDate
    }

    /// "Download updates automatically" (Settings' Updates page, HAIL-52
    /// contract): Sparkle's own `automaticallyDownloadsUpdates`, which
    /// Sparkle persists itself (backed by the `SUAutomaticallyUpdate`
    /// Info.plist default, `true` for a release build - scripts/bundle-app.sh
    /// - until a tester overrides it here). `false` when updates are
    /// unavailable in this build (no controller); the setter is then a no-op,
    /// same as `checkForUpdates()`.
    static var automaticallyDownloadsUpdates: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    /// The app's marketing version (CFBundleShortVersionString). The daemon
    /// handoff (KNOCK-21) compares it with `service.status.version` and asks the
    /// daemon to restart when the app is newer than the running binary.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
