import Testing
import Foundation
@testable import Knock

/// WAG-318: the update check on start and its prompt.
@MainActor
struct UpdatePromptTests {
    private func withTempDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suiteName = "knock-update-prompt-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    private let offer = UpdatePromptModel.Offer(version: "0.2.22", whatsNew: ["A thing"])

    // Launch check rule: once per start, not in dev, not with the setting off.
    @Test func runsOnceInAReleaseBuild() {
        #expect(LaunchUpdateCheck.shouldRun(isAvailable: true, enabled: true, alreadyRan: false, scriptedCheck: false))
        #expect(!LaunchUpdateCheck.shouldRun(isAvailable: true, enabled: true, alreadyRan: true, scriptedCheck: false))
    }

    @Test func staysInertInADevBuild() {
        #expect(!LaunchUpdateCheck.shouldRun(isAvailable: false, enabled: true, alreadyRan: false, scriptedCheck: false))
    }

    @Test func theE2EScriptOwnsItsOwnCheck() {
        #expect(!LaunchUpdateCheck.shouldRun(isAvailable: true, enabled: true, alreadyRan: false, scriptedCheck: true))
    }

    // Setting off.
    @Test func settingIsOnByDefaultAndCanTurnOff() {
        withTempDefaults { defaults in
            #expect(LaunchUpdateCheckSettings.isEnabled(defaults: defaults))
            LaunchUpdateCheckSettings.setEnabled(false, defaults: defaults)
            #expect(!LaunchUpdateCheckSettings.isEnabled(defaults: defaults))
            LaunchUpdateCheckSettings.setEnabled(true, defaults: defaults)
            #expect(LaunchUpdateCheckSettings.isEnabled(defaults: defaults))
        }
    }

    @Test func settingOffStopsTheCheck() {
        #expect(!LaunchUpdateCheck.shouldRun(isAvailable: true, enabled: false, alreadyRan: false, scriptedCheck: false))
    }

    // Skip-version rule.
    @Test func skipHidesThePromptAndRemembersTheVersion() {
        withTempDefaults { defaults in
            let model = UpdatePromptModel()
            model.present(offer)
            model.skip(defaults: defaults)
            #expect(model.offer == nil)
            #expect(SkippedUpdateVersion.isSkipped("0.2.22", defaults: defaults))
        }
    }

    @Test func aNewerVersionAsksAgainAfterASkip() {
        withTempDefaults { defaults in
            SkippedUpdateVersion.skip("0.2.22", defaults: defaults)
            #expect(SkippedUpdateVersion.isSkipped("0.2.22", defaults: defaults))
            #expect(!SkippedUpdateVersion.isSkipped("0.2.23", defaults: defaults))
        }
    }

    // Later rule: hides now, stores nothing, so the next start asks again.
    @Test func laterHidesAndStoresNothing() {
        withTempDefaults { defaults in
            let model = UpdatePromptModel()
            model.present(offer)
            model.later()
            #expect(model.offer == nil)
            #expect(SkippedUpdateVersion.current(defaults: defaults) == nil)
            let nextStart = UpdatePromptModel()
            nextStart.present(offer)
            #expect(nextStart.offer == offer)
        }
    }

    // Install: only the person's press starts the download.
    @Test func installStartsOnlyOnThePress() {
        let model = UpdatePromptModel()
        var started = 0
        model.startInstall = { started += 1 }
        model.present(offer)
        #expect(started == 0)
        model.install()
        model.install()
        #expect(started == 1)
        #expect(model.isInstalling)
    }

    @Test func aFailedInstallClosesThePrompt() {
        let model = UpdatePromptModel()
        model.present(offer)
        model.install()
        model.installFailed()
        #expect(model.offer == nil)
        #expect(!model.isInstalling)
    }

    @Test func anUpdateWaitingBehindTheToastOrSkippedDoesNotPrompt() {
        #expect(LaunchUpdateCheck.shouldPrompt(version: "1", skipped: false, updateWaiting: false))
        #expect(!LaunchUpdateCheck.shouldPrompt(version: "1", skipped: true, updateWaiting: false))
        #expect(!LaunchUpdateCheck.shouldPrompt(version: "1", skipped: false, updateWaiting: true))
    }

    @Test func installAtOnceCallsTheInstallerWithoutAToast() {
        var installed = 0
        let model = UpdateReadyModel()
        Updater.installRequested = true
        let result = UpdaterLogDelegate.armInstallOnQuit(
            version: "0.2.22", headline: nil, installNow: { installed += 1 }, toastEnabled: true,
            installAtOnce: true, model: model)
        #expect(result)
        #expect(installed == 1)
        #expect(!model.isReady)
        #expect(!Updater.installRequested)
    }

    @Test func whatsNewKeepsTheFirstThreeBulletsWithoutMarkers() {
        let notes = "# Waggle 0.2.21\n\n- **Comment right on the request.** Pin comments.\n- **Tidier rows.** Shrinks.\n- Plain\n- Fourth"
        #expect(LaunchUpdateCheck.whatsNew(fromReleaseNotes: notes) == [
            "Comment right on the request.", "Tidier rows.", "Plain",
        ])
        #expect(LaunchUpdateCheck.whatsNew(fromReleaseNotes: nil).isEmpty)
    }
}
