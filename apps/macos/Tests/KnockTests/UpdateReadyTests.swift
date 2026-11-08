import Testing
@testable import Knock

@MainActor
struct UpdateReadyTests {
    @Test func headlineIsTheFirstStandaloneBoldLine() {
        let notes = """
        # Knock 0.1.15

        *Your agents knock before they ship. Defuse the slop before it lands.*

        **Your answer, always in view**

        - **The options stay at the bottom.** However long the ask...

        **After updating:** nothing to do.
        """
        #expect(UpdateReadyModel.headline(fromReleaseNotes: notes) == "Your answer, always in view")
    }

    @Test func noHeadlineWhenNotesHaveNone() {
        #expect(UpdateReadyModel.headline(fromReleaseNotes: nil) == nil)
        #expect(UpdateReadyModel.headline(fromReleaseNotes: "- a fix\n\n**After updating:** nothing to do.") == nil)
    }

    @Test func showsOnceReadyHidesOnLaterAndRestartCallsSparkle() {
        let model = UpdateReadyModel()
        #expect(!model.isVisible)
        var installs = 0
        model.present(.init(version: "0.1.16", headline: nil), installNow: { installs += 1 })
        #expect(model.isVisible)
        model.restartNow()
        #expect(installs == 1)
        model.later()
        #expect(!model.isVisible)
    }

    /// HAIL-52: the Updates page's chip stays "Update ready" once an update
    /// has downloaded, even after the toast itself is dismissed - dismissing
    /// the toast never un-readies the update (it still installs on quit).
    @Test func isReadyStaysTrueAfterTheToastIsDismissed() {
        let model = UpdateReadyModel()
        #expect(!model.isReady)
        model.present(.init(version: "0.1.16", headline: nil), installNow: {})
        #expect(model.isReady)
        model.later()
        #expect(!model.isVisible)
        #expect(model.isReady)
    }

    @Test func whatsNewPointsAtTheReleasePage() {
        #expect(UpdateReadyModel.releaseNotesURL(version: "0.1.16").absoluteString
            == "https://github.com/limone-eth/knock-releases/releases/tag/v0.1.16")
    }

    @Test func checkForUpdatesBringsBackAHiddenToastWhenAnUpdateIsWaiting() {
        let model = UpdateReadyModel()
        #expect(!model.showAgainIfReady(), "nothing waiting: the caller runs a normal Sparkle check")
        model.present(.init(version: "0.1.21", headline: nil), installNow: {})
        model.later()
        #expect(!model.isVisible)
        #expect(model.showAgainIfReady())
        #expect(model.isVisible)
    }
}

/// HAIL-80: the toast waits for an operator click. These drive the delegate
/// decisions apart from Sparkle's types.
@MainActor
struct UpdateToastStaysTests {
    @Test func armingShowsTheToastAndKeepsSparklesInstallHandlerUnused() {
        let model = UpdateReadyModel()
        var installs = 0
        let keepsControl = UpdaterLogDelegate.armInstallOnQuit(
            version: "0.1.30", headline: nil, installNow: { installs += 1 }, toastEnabled: true, model: model)
        #expect(keepsControl, "true tells Sparkle Waggle owns the install")
        #expect(model.isVisible)
        #expect(installs == 0, "nothing installs until Restart now")
    }

    @Test func theToastHasNoTimerSoItStaysUntilTheOperatorActs() async throws {
        let model = UpdateReadyModel()
        _ = UpdaterLogDelegate.armInstallOnQuit(
            version: "0.1.30", headline: nil, installNow: {}, toastEnabled: true, model: model)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(model.isVisible)
        model.later()
        #expect(!model.isVisible)
        #expect(model.isReady, "Later hides the toast, the update still installs on quit")
    }

    @Test func toastOffStillKeepsControlOfTheInstallButShowsNothing() {
        let model = UpdateReadyModel()
        let keepsControl = UpdaterLogDelegate.armInstallOnQuit(
            version: "0.1.30", headline: nil, installNow: {}, toastEnabled: false, model: model)
        #expect(keepsControl)
        #expect(!model.isVisible)
    }

    @Test func restartNowRunsTheInstallHandlerOnce() {
        let model = UpdateReadyModel()
        var installs = 0
        _ = UpdaterLogDelegate.armInstallOnQuit(
            version: "0.1.30", headline: nil, installNow: { installs += 1 }, toastEnabled: true, model: model)
        model.restartNow()
        #expect(installs == 1)
    }

    @Test func scheduledSparkleUIBecomesTheToastButAUserCheckKeepsSparklesAlert() {
        typealias D = UpdaterLogDelegate
        #expect(D.presentsToastForSparkleUI(handledBySparkle: false, userInitiated: false, toastEnabled: true))
        #expect(!D.presentsToastForSparkleUI(handledBySparkle: false, userInitiated: true, toastEnabled: true))
        #expect(!D.presentsToastForSparkleUI(handledBySparkle: true, userInitiated: false, toastEnabled: true))
        #expect(!D.presentsToastForSparkleUI(handledBySparkle: false, userInitiated: false, toastEnabled: false))
    }

    // HAIL-192
    @Test func restartWarningNamesTheWaitingAgentsInPlainWords() {
        #expect(UpdateReadyModel.restartWarning(waitingAgents: 0) == nil)
        #expect(UpdateReadyModel.restartWarning(waitingAgents: 1)
            == "1 agent is waiting for your reply. Restarting is safe: it gets your answer after Waggle reopens.")
        let many = UpdateReadyModel.restartWarning(waitingAgents: 3)
        #expect(many?.hasPrefix("3 agents are waiting for your reply.") == true)
        #expect(many?.contains("\u{2014}") == false)
    }

    @Test func failedReplyOffersCopyOnlyWhenTheSessionIsGone() {
        func item(_ state: SessionState?) -> Case {
            Case(
                id: "c_1", taskId: "t_1", kind: .question, title: "Title",
                need: "Need", why: "Why", recommendation: "a",
                recommendationWhy: "Because", options: [Option(id: "a", label: "Compact")], status: .waitingOnAgent,
                hasArtifact: false, latestReplyId: "reply_1", latestReplyState: .failed,
                latestReplyChoice: "a", sessionState: state,
                createdAt: "2026-09-26T10:00:00.000Z", updatedAt: "2026-09-26T10:00:00.000Z")
        }
        #expect(DeliveryOutcomeBanner.copyLine(for: item(.ended)) != nil)
        #expect(DeliveryOutcomeBanner.copyLine(for: item(.live)) == nil)
        #expect(DeliveryOutcomeBanner.copyLine(for: item(nil)) == nil)
    }
}
