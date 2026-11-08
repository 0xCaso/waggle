import Foundation
import Testing
@testable import Knock

/// WAG-366: app use, the newer screens and per-ask counts in the local usage log.
@MainActor
struct WAG366Tests {
    private func json(_ record: UsageRecord) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    }

    /// Runs `body` with a recorder as the app's reporter. No suspension inside, so no other test sees it.
    private func recorded(_ body: () -> Void) -> [UsageRecord] {
        let recorder = UsageRecorder()
        let before = UsageReporter.current
        UsageReporter.current = recorder.reporter
        defer { UsageReporter.current = before }
        body()
        return recorder.records
    }

    @Test func aRecordEncodesOnlyTheFieldsItHolds() throws {
        let launched = try json(UsageRecord(.appLaunched))
        #expect(launched.keys.sorted() == ["event"])
        let started = try json(UsageRecord(.newIdeaStarted, variantName: "claudeTerminal", n: 2))
        #expect(started["variant"] as? String == "claudeTerminal")
        #expect(started["n"] as? Int == 2)
        let picked = try json(UsageRecord(.detailFormatPicked, variantName: "numbers", caseId: "c_1", format: "none"))
        #expect(picked["case_id"] as? String == "c_1")
        #expect(picked["format"] as? String == "none")
        #expect(picked["variant"] as? String == "numbers")
        // The HAIL-83 variants keep their wire words.
        let zoom = try json(UsageRecord(.screenshotZoomChanged, variant: .hundred))
        #expect(zoom["variant"] as? String == "100")
    }

    @Test func theSendingReporterNamesTheOpenAskOnAskEventsOnly() {
        let recorder = UsageRecorder()
        recorder.reporter.attachesAsk = true
        recorder.reporter.record(.replyTyped)
        recorder.reporter.askOpened(caseId: "c_1")
        recorder.reporter.record(.replyTyped)
        recorder.reporter.record(.sourcesListOpened)
        recorder.reporter.record(.sessionsPanelOpened)
        recorder.reporter.record(.settingsPageOpened, variantName: "phone")
        recorder.reporter.recordOnce(.reviewOpened, caseId: "c_2", artifactKind: .markdown, timed: true)
        #expect(recorder.records.map(\.caseId) == [nil, "c_1", "c_1", nil, nil, "c_2"])
    }

    @Test func aPlainReporterSendsNoAskId() {
        let recorder = UsageRecorder()
        recorder.reporter.askOpened(caseId: "c_1")
        recorder.reporter.record(.replyTyped)
        recorder.reporter.recordOnce(.reviewOpened, caseId: "c_1")
        #expect(recorder.records.allSatisfy { $0.caseId == nil })
    }

    @Test func everyAskEventIsOneTheDaemonTakesAnAskIdOn() {
        let bare: [UsageEvent] = [
            .sessionsPanelOpened, .sessionDetailOpened, .copyPromptClicked, .appLaunched, .appActive,
            .settingsPageOpened, .newIdeaStarted, .splitFoldToggled, .updatePromptShown, .usageExported,
        ]
        #expect(bare.allSatisfy { !$0.isAskBound })
        let onAsk: [UsageEvent] = [.caseOpened, .sourceOpened, .detailFormatPicked, .nudgeClicked]
        #expect(onAsk.allSatisfy { $0.isAskBound })
    }

    @Test func appActiveIsRecordedOncePerHour() {
        let recorder = UsageRecorder()
        recorder.now = Date(timeIntervalSince1970: 3_600 * 10 + 5)
        recorder.reporter.appBecameActive()
        recorder.now += 600
        recorder.reporter.appBecameActive()
        recorder.now += 3_600
        recorder.reporter.appBecameActive()
        #expect(recorder.events == [.appActive, .appActive])
    }

    @Test func foldsReportWhichSideWasToggled() throws {
        let suite = "wag366-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let records = recorded {
            let fold = SplitFoldState(defaults: defaults, environment: [:])
            fold.toggleQueue()
            fold.toggleAsk()
            fold.toggleBothFolded()
        }
        #expect(records.filter { $0.event == .splitFoldToggled }.map(\.variant) == ["queue", "ask", "both"])
    }

    @Test func theTourReportsItsStartAndHowItEnded() {
        let records = recorded {
            let tour = CoachMarkTourModel()
            tour.start(caseId: "c_1")
            tour.skip()
            tour.start(caseId: "c_1")
            tour.next()
            tour.next()
        }
        #expect(records.map(\.event) == [.tourStarted, .tourSkipped, .tourStarted, .tourFinished])
    }

    @Test func aSettingsPageIsReportedOnAChangeOnly() {
        let records = recorded {
            let navigation = SettingsNavigationModel(environment: [:])
            let first = navigation.selected
            navigation.selected = first
            navigation.selected = first == .phone ? .help : .phone
        }
        #expect(records.map(\.event) == [.settingsPageOpened])
        #expect(records.first?.variant == "phone" || records.first?.variant == "help")
    }

    @Test func theQuickAsksHaveOneUsageWordEach() {
        #expect(ComposerViewModel.detailChips.count == ComposerViewModel.detailChipUsageNames.count)
        #expect(GettingStartedLine.allCases.map(\.usageName) == ["connect", "job", "decision", "talk", "notifications", "design_kit"])
    }
}
