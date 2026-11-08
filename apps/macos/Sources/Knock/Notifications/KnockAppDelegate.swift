import AppKit
import UserNotifications

/// Wires the pieces this story owns to the running app: requests
/// notification permission at launch, posts one notification per
/// `case.created` `needs_you` case, and opens the exact case a notification
/// click names. `KnockApp` creates the single `AppModel` and calls
/// `attach(to:)` once that model exists.
@MainActor
final class KnockAppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: AppModel?
    private var notificationController: NotificationCenterController?
    private var menuBarController: MenuBarController?
    private var screenshotController: ScreenshotController?
    private var dockBadgeController: DockBadgeController?
    private var notifyTask: Task<Void, Never>?
    private var t3ReminderTask: Task<Void, Never>?

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppAppearance.apply()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = NotificationCenterController { [weak self] caseId, opensComments in
            Task {
                if opensComments { await self?.model?.openComments(caseId: caseId) }
                else { await self?.model?.open(caseId: caseId, source: .notification) }
            }
            AppActivation.showMainWindow()
        }
        controller.requestAuthorization()
        notificationController = controller
        // HAIL-180: a release build in Knock.app moves itself to Waggle.app first, so the plugin
        // refresh below sees the new bundle path. When the move happens this process quits.
        if AppSelfRename.runAtLaunch() { return }
        PluginRefresh.runAtLaunch()
        // WAG-277: register this bundle with Launch Services once per version (icon fix).
        LaunchServicesRegistration.runAtLaunch()
        // HAIL-176: move the Claude app's old `knock` entry to `waggle`, once per launch.
        if ClaudeAppMigration.shouldRun() {
            ClaudeAppMigration.run(config: .standard(), binaryPath: { KnockBinaryLocator.resolve()?.path })
        }
        // HAIL-180: also repair paths a hand rename left behind (Claude app entry, ~/.local/bin links).
        if BundlePathRepair.shouldRun(), let binary = KnockBinaryLocator.bundledBinary() {
            BundlePathRepair.runAtLaunch(
                config: .standard(), home: FileManager.default.homeDirectoryForCurrentUser, binaryPath: binary)
        }

        // The M1 setup window itself is opened by `OnboardingLaunchGate`
        // (KnockApp.swift), which has the SwiftUI `openWindow` environment
        // action this delegate does not.
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        UsageReporter.current?.appBecameActive()
    }

    func attach(to model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        let client = model.client
        let screenshots = ScreenshotController(
            loadSessions: { (try? await client.sessionsList()) ?? [] },
            loadCases: {
                async let needsYou = client.casesList(status: .needsYou)
                async let waiting = client.casesList(status: .waitingOnAgent)
                return ((try? await needsYou) ?? []) + ((try? await waiting) ?? [])
            },
            sendPrompt: { sessionId, text in try await client.sessionSendPrompt(sessionId: sessionId, text: text) })
        screenshotController = screenshots
        if let folder = ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_SCREENSHOT"], !folder.isEmpty {
            screenshots.runEvidence(into: folder)
        }
        menuBarController = MenuBarController(model: model, screenshots: screenshots)
        dockBadgeController = DockBadgeController(counts: model.$needsYouCases.map(\.count))
        notifyTask = Task { [weak self] in
            for await content in model.caseNotifications {
                self?.notificationController?.notify(content)
            }
        }
        // WAG-264: one quiet reminder, three days before the T3 Code token ends. It reads no Keychain item.
        t3ReminderTask = Task {
            while !Task.isCancelled {
                T3RenewReminder.check(meta: UserDefaultsT3Meta(), now: Date()) {
                    let content = UNMutableNotificationContent()
                    content.title = T3RenewReminder.text
                    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "t3code.renew", content: content, trigger: nil))
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }
}
