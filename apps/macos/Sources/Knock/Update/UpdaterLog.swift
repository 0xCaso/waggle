import AppKit
import Sparkle

/// Writes one line per Sparkle event to `~/Library/Logs/Knock/update.log` so a
/// pilot friend's update failures are diagnosable from a log file alone
/// (KNOCK-21 amendment). `SPUStandardUpdaterController` holds its delegate
/// weakly, so `Updater` keeps this instance alive for the app's lifetime.
@MainActor
final class UpdaterLogDelegate: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    private var handle: FileHandle?
    private let stamp = ISO8601DateFormatter()

    /// The folder this delegate writes `update.log` into. Not inlined into
    /// `init` below: the Settings window's Data & privacy page (HAIL-50)
    /// reuses this exact path for its "Show logs" button, so the two never
    /// drift apart.
    nonisolated static func logDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        // A test or dev copy (its own KNOCK_HOME) logs under that folder, never
        // into the operator's real ~/Library/Logs/Knock/update.log.
        if let knockHome = environment["KNOCK_HOME"], !knockHome.isEmpty {
            return URL(fileURLWithPath: knockHome).appendingPathComponent("logs", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Knock", isDirectory: true)
    }

    override init() {
        super.init()
        let dir = Self.logDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("update.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let opened = try? FileHandle(forWritingTo: url)
        if let opened {
            _ = try? opened.seekToEnd()
        }
        handle = opened
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let pid = ProcessInfo.processInfo.processIdentifier
        log("appLaunch version=\(version) pid=\(pid)")
        UpdateReadyModel.shared.log = { [weak self] in self?.log($0) }
        UpdatePromptModel.shared.log = { [weak self] in self?.log($0) }
    }

    func logLine(_ line: String) { log(line) }

    private func log(_ line: String) {
        guard let handle else { return }
        handle.write(Data(("\(stamp.string(from: Date())) \(line)\n").utf8))
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        log("didFinishLoading appcast items=\(appcast.items.count)")
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        log("didFindValidUpdate \(item.displayVersionString) (build \(item.versionString))")
        Updater.launchProbeFound(version: item.displayVersionString, releaseNotes: item.itemDescription)
    }

    /// A skipped version stays quiet in every check the person did not start
    /// (WAG-318). "Check for Updates…" still finds it.
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        if updateCheck != .updates && SkippedUpdateVersion.isSkipped(item.displayVersionString) {
            log("skippedVersion \(item.displayVersionString)")
            throw NSError(domain: "dev.limone.knock.update", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Version \(item.displayVersionString) is skipped"])
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let info = (error as NSError).userInfo
        let reason = info[SPUNoUpdateFoundReasonKey] ?? "unknown"
        let latest = info[SPULatestAppcastItemFoundKey] ?? "none"
        log("updaterDidNotFindUpdate reason=\(reason) latest=\(latest)")
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        log("didDownloadUpdate \(item.displayVersionString) (build \(item.versionString))")
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        log("failedToDownloadUpdate \(item.displayVersionString): \(error)")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Updater.launchProbeActive = false
        if Updater.installRequested {
            Updater.installRequested = false
            UpdatePromptModel.shared.installFailed()
        }
        let ns = error as NSError
        let underlying = ns.userInfo[NSUnderlyingErrorKey] ?? "none"
        log("didAbortWithError \(ns.domain)/\(ns.code) \(ns.localizedDescription) underlying=\(underlying)")
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        log("didExtractUpdate \(item.displayVersionString) (build \(item.versionString))")
    }

    /// A downloaded update will install on quit: keep Sparkle's
    /// install-now handler and show the update toast (`UpdateReadyModel`),
    /// unless "Show a toast when an update is ready" is off (HAIL-52
    /// contract) - the update still installs on quit either way; this only
    /// gates the toast. Returning true stalls further update cycles; Sparkle
    /// still installs the update when Knock quits (SPUUpdaterDelegate.h).
    /// The toast has no timer: it stays until "Restart now" or "Later"
    /// (HAIL-80), and nothing here calls `immediateInstallHandler` on its own.
    func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        log("willInstallUpdateOnQuit \(item.displayVersionString) (build \(item.versionString))")
        return Self.armInstallOnQuit(
            version: item.displayVersionString,
            headline: UpdateReadyModel.headline(fromReleaseNotes: item.itemDescription),
            installNow: immediateInstallHandler,
            toastEnabled: UpdateToastSettings.isEnabled() && !SkippedUpdateVersion.isSkipped(item.displayVersionString),
            installAtOnce: Updater.installRequested
        )
    }

    /// The decision behind `willInstallUpdateOnQuit`, apart from Sparkle's
    /// types so a test can drive it. Always true: Knock keeps the install
    /// under its own control (never an automatic relaunch without the person
    /// pressing Install), toast or not.
    static func armInstallOnQuit(
        version: String, headline: String?, installNow: @escaping () -> Void, toastEnabled: Bool,
        installAtOnce: Bool = false,
        model: UpdateReadyModel = .shared
    ) -> Bool {
        if installAtOnce {
            // The person pressed "Install and restart" in the start prompt.
            Updater.installRequested = false
            installNow()
            return true
        }
        if toastEnabled {
            model.present(.init(version: version, headline: headline), installNow: installNow)
        }
        return true
    }

    // MARK: SPUStandardUserDriverDelegate (HAIL-80)
    //
    // Sparkle's install-and-relaunch runs only through two doors: the
    // `immediateInstallationBlock` above (the toast's "Restart now"), or
    // Sparkle's own standard UI ("Install Update" / "Install and Relaunch").
    // That UI drives a scheduled check whenever the automatic driver is not
    // used (an installer already waiting from an earlier launch, a resumable
    // update, "Download updates automatically" off). Its windows bypass the
    // toast. Declaring gentle reminders keeps Sparkle from showing a
    // scheduled alert on its own: the toast shows instead, and its button
    // brings Sparkle's alert up on purpose.

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        log("scheduledUpdateHeldForToast \(update.displayVersionString) immediateFocus=\(immediateFocus)")
        return false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard Self.presentsToastForSparkleUI(
            handledBySparkle: handleShowingUpdate, userInitiated: state.userInitiated,
            toastEnabled: UpdateToastSettings.isEnabled())
        else { return }
        UpdateReadyModel.shared.present(
            .init(
                version: update.displayVersionString,
                headline: UpdateReadyModel.headline(fromReleaseNotes: update.itemDescription)
            ),
            installNow: { Updater.controller?.checkForUpdates(nil) }
        )
    }

    /// A scheduled update Sparkle would have shown itself becomes the toast.
    /// The operator's own "Check for Updates…" keeps Sparkle's alert.
    nonisolated static func presentsToastForSparkleUI(
        handledBySparkle: Bool, userInitiated: Bool, toastEnabled: Bool
    ) -> Bool {
        !handledBySparkle && !userInitiated && toastEnabled
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        log("willInstallUpdate \(item.displayVersionString) (build \(item.versionString))")
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        log("updaterShouldRelaunchApplication")
        return true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        log("updaterWillRelaunchApplication")
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error {
            log("didFinishUpdateCycle check=\(updateCheck.rawValue) error=\(error)")
        } else {
            log("didFinishUpdateCycle check=\(updateCheck.rawValue) ok")
        }
    }
}
