import AppKit
import Foundation
import Testing
@testable import Knock

/// HAIL-83: what people click. Every call site reports through a
/// `UsageReporter`; these tests swap its sink for a recorder and read back
/// exactly what would have gone over `usage.record`.
@MainActor
private final class RecorderBox {
    var records: [UsageRecord] = []
    var now = Date(timeIntervalSince1970: 1_000)
    var reporter: UsageReporter!
}

@MainActor
final class UsageRecorder {
    private let box = RecorderBox()

    var reporter: UsageReporter { box.reporter }

    init() {
        let box = self.box
        box.reporter = UsageReporter(
            clock: { box.now },
            sink: { box.records.append($0) })
    }

    var records: [UsageRecord] { box.records }
    var now: Date {
        get { box.now }
        set { box.now = newValue }
    }

    var events: [UsageEvent] { records.map(\.event) }
}

@MainActor
struct UsageClickTests {
    private func optionsCase(id: String = "c1") -> Case {
        Case(
            id: id, taskId: "t1", kind: .question, title: "Layout",
            need: "Pick one", why: "Not a technical call",
            recommendation: "a", recommendationWhy: "It is faster",
            options: [Option(id: "a", label: "A"), Option(id: "b", label: "B")],
            status: .needsYou, hasArtifact: false,
            createdAt: "2026-09-26T10:00:00Z", updatedAt: "2026-09-26T10:00:00Z"
        )
    }

    private func answeredCase() -> Case {
        Case(
            id: "c9", taskId: "t1", kind: .question, title: "Layout",
            need: "Pick one", why: "Not a technical call",
            recommendation: "a", recommendationWhy: "It is faster",
            options: [Option(id: "a", label: "A"), Option(id: "b", label: "B")],
            status: .waitingOnAgent, hasArtifact: false,
            latestReplyId: "reply_1", latestReplyState: .queued, latestReplyChoice: "a",
            createdAt: "2026-09-26T10:00:00Z", updatedAt: "2026-09-26T10:00:00Z"
        )
    }

    private func tempHome() -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("knock_usage_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func sendFlow(_ knockCase: Case, usage: UsageReporter) -> SendFlowController {
        let client = KnockClient(socketPath: "/tmp/knock-no-such-\(UUID().uuidString.prefix(6)).sock")
        let coordinator = SendCoordinator(client: client, store: PendingReplyStore(environment: ["KNOCK_HOME": tempHome()]))
        return SendFlowController(
            knockCase: knockCase, commentsStore: CommentsSessionStore(), coordinator: coordinator,
            draftStore: ComposerDraftStore(), usage: usage, onSent: {})
    }

    // MARK: - The wire shape

    @Test func afterBucketsCoverEverySecondCount() {
        #expect(UsageAfter(seconds: 0) == .s0to2)
        #expect(UsageAfter(seconds: 2.9) == .s0to2)
        #expect(UsageAfter(seconds: 3) == .s3to10)
        #expect(UsageAfter(seconds: 10.9) == .s3to10)
        #expect(UsageAfter(seconds: 11) == .s11to60)
        #expect(UsageAfter(seconds: 60.9) == .s11to60)
        #expect(UsageAfter(seconds: 61) == .s60plus)
        #expect(UsageAfter(seconds: 9_999) == .s60plus)
    }

    @Test func aRecordEncodesOnlyItsOwnClosedFields() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func json(_ record: UsageRecord) throws -> String {
            String(decoding: try encoder.encode(record), as: UTF8.self)
        }
        #expect(try json(UsageRecord(.replyTyped)) == #"{"event":"reply_typed"}"#)
        #expect(try json(UsageRecord(.caseOpened, source: "sessions_panel"))
            == #"{"event":"case_opened","source":"sessions_panel"}"#)
        #expect(try json(UsageRecord(.artifactOpenedFull, artifactKind: .htmlBundle, afterS: .s11to60))
            == #"{"after_s":"11-60","artifact_kind":"html_bundle","event":"artifact_opened_full"}"#)
        #expect(try json(UsageRecord(.screenshotZoomChanged, variant: .hundred))
            == #"{"event":"screenshot_zoom_changed","variant":"100"}"#)
    }

    // MARK: - The reporter

    @Test func onceEventsRecordOncePerOpeningAndCarryTheAfterBucket() {
        let recorder = UsageRecorder()
        let reporter = recorder.reporter
        reporter.askOpened(caseId: "c1")
        recorder.now = recorder.now.addingTimeInterval(5)
        #expect(reporter.recordOnce(.artifactOpenedFull, caseId: "c1", artifactKind: .screenshot, timed: true))
        recorder.now = recorder.now.addingTimeInterval(100)
        #expect(!reporter.recordOnce(.artifactOpenedFull, caseId: "c1", artifactKind: .screenshot, timed: true))
        #expect(recorder.records == [UsageRecord(.artifactOpenedFull, artifactKind: .screenshot, afterS: .s3to10)])

        // Opening the ask again starts a new opening.
        reporter.askOpened(caseId: "c1")
        recorder.now = recorder.now.addingTimeInterval(70)
        reporter.recordOnce(.artifactOpenedFull, caseId: "c1", artifactKind: .screenshot, timed: true)
        #expect(recorder.records.last?.afterS == .s60plus)
        #expect(recorder.records.count == 2)
    }

    @Test func aDifferentAskHasItsOwnOnceSet() {
        let recorder = UsageRecorder()
        recorder.reporter.askOpened(caseId: "c1")
        recorder.reporter.recordOnce(.reviewOpened, caseId: "c1", artifactKind: .markdown, timed: true)
        recorder.reporter.recordOnce(.reviewOpened, caseId: "c2", artifactKind: .markdown, timed: true)
        #expect(recorder.events == [.reviewOpened, .reviewOpened])
    }

    // MARK: - The composer

    @Test func pickingByClickAndByNumberKeyIsReportedAndClearingIsNot() {
        let recorder = UsageRecorder()
        let composer = ComposerViewModel(knockCase: optionsCase(), usage: recorder.reporter)
        composer.selectOption("a")
        composer.selectOption(atPosition: 2)
        composer.selectOption(atPosition: 2)  // clears the pick
        composer.selectOption(atPosition: 9)  // no such option
        #expect(recorder.records == [
            UsageRecord(.optionPicked, source: "click"),
            UsageRecord(.optionPicked, source: "number_key"),
        ])
    }

    @Test func theFirstKeystrokeIsReportedOncePerAsk() {
        let recorder = UsageRecorder()
        let composer = ComposerViewModel(knockCase: optionsCase(), usage: recorder.reporter)
        composer.draftText = "set by the app"
        #expect(recorder.records.isEmpty, "text the app sets is not a keystroke")
        composer.replyEdited()
        composer.replyEdited()
        #expect(recorder.records == [UsageRecord(.replyTyped)])
    }

    @Test func askingForMoreDetailIsReported() {
        let recorder = UsageRecorder()
        let composer = ComposerViewModel(knockCase: optionsCase(), usage: recorder.reporter)
        composer.beginAskingForDetail()
        #expect(recorder.records == [UsageRecord(.askMoreDetailOpened)])
    }

    @Test func acceptingTheRecommendationNamesButtonOrShortcut() {
        let recorder = UsageRecorder()
        let flow = sendFlow(optionsCase(), usage: recorder.reporter)
        flow.acceptRecommendation()
        #expect(recorder.records == [UsageRecord(.recommendationAccepted, source: "button")])
        let second = UsageRecorder()
        let other = sendFlow(optionsCase(id: "c2"), usage: second.reporter)
        other.acceptRecommendation(via: .shortcut)
        #expect(second.records == [UsageRecord(.recommendationAccepted, source: "shortcut")])
    }

    @Test func changingAnAnswerIsReported() {
        let recorder = UsageRecorder()
        let flow = sendFlow(answeredCase(), usage: recorder.reporter)
        flow.beginChangingAnswer()
        #expect(recorder.records == [UsageRecord(.changeAnswerStarted)])
    }

    @Test func aComposerWithNoReporterReportsNothingAndStillWorks() {
        let composer = ComposerViewModel(knockCase: optionsCase())
        composer.selectOption("a")
        composer.replyEdited()
        composer.beginAskingForDetail()
        #expect(composer.selectedOptionId == "a")
        #expect(composer.isAskingForDetail)
    }

    // MARK: - The screenshot stage

    @Test func onlyAPersonsZoomChoiceIsReported() {
        let recorder = UsageRecorder()
        let stage = ScreenshotStageModel(usage: recorder.reporter)
        stage.updateViewport(container: CGSize(width: 800, height: 600), image: CGSize(width: 1600, height: 1200))
        stage.fit()  // a new screen resets to Fit by itself
        stage.showOne()
        #expect(recorder.records.isEmpty)
        stage.userZoomIn()
        stage.userActualSize()
        stage.userFit()
        stage.userZoomOut()
        stage.userShowSet(current: nil)
        #expect(recorder.records == [
            UsageRecord(.screenshotZoomChanged, variant: .zoom),
            UsageRecord(.screenshotZoomChanged, variant: .hundred),
            UsageRecord(.screenshotZoomChanged, variant: .fit),
            UsageRecord(.screenshotZoomChanged, variant: .zoom),
            UsageRecord(.screenshotSetViewOpened),
        ])
    }

    // MARK: - Comments

    @Test func aSavedCommentIsReportedAsPointOrRegionAndAnEmptyNoteIsNot() {
        let recorder = UsageRecorder()
        let store = CommentsSessionStore()
        store.usage = recorder.reporter
        store.addCapture(image: NSImage(size: NSSize(width: 10, height: 10)), revision: 1)

        store.beginDraft(rect: Rect(x: 0.1, y: 0.1, w: 0.1, h: 0.1), variant: .point)
        store.updateDraftText("a click")
        store.commitDraft()
        store.beginDraft(rect: Rect(x: 0.2, y: 0.2, w: 0.3, h: 0.3))
        store.updateDraftText("a drag")
        store.commitDraft()
        store.beginDraft(rect: Rect(x: 0.5, y: 0.5, w: 0.1, h: 0.1), variant: .point)
        store.updateDraftText("   ")
        store.commitDraft()

        #expect(recorder.records == [
            UsageRecord(.commentAdded, artifactKind: .htmlBundle, variant: .point),
            UsageRecord(.commentAdded, artifactKind: .htmlBundle, variant: .region),
        ])
    }

    // MARK: - The app model

    private func model(_ recorder: UsageRecorder) throws -> AppModel {
        let client = KnockClient(socketPath: "/tmp/knock-no-such-\(UUID().uuidString.prefix(6)).sock")
        let suite = "usage-click-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return AppModel(client: client, environment: isolatedKnockEnvironment(), bundleIdentifier: nil, defaults: defaults, usage: recorder.reporter)
    }

    @Test func aPreviewOpenNeedsAnArtifactAndIsOncePerAsk() throws {
        let recorder = UsageRecorder()
        let model = try model(recorder)
        model.usage.askOpened(caseId: "c1")
        model.recordPreviewOpen(.artifactOpenedFull, caseId: "c1", artifactKind: nil)
        #expect(recorder.records.isEmpty, "an ask with no artifact reports nothing")
        model.recordPreviewOpen(.artifactOpenedFull, caseId: "c1", artifactKind: .htmlBundle)
        model.recordPreviewOpen(.artifactOpenedFull, caseId: "c1", artifactKind: .htmlBundle)
        model.recordPreviewOpen(.reviewOpened, caseId: "c1", artifactKind: .htmlBundle)
        model.recordPreviewInteraction(caseId: "c1", artifactKind: .htmlBundle)
        model.recordPreviewInteraction(caseId: "c1", artifactKind: .htmlBundle)
        #expect(recorder.records == [
            UsageRecord(.artifactOpenedFull, artifactKind: .htmlBundle, afterS: .s0to2),
            UsageRecord(.reviewOpened, artifactKind: .htmlBundle, afterS: .s0to2),
            UsageRecord(.previewInteracted, artifactKind: .htmlBundle),
        ])
    }

    @Test func nudgeAndCopyPromptClicksAreReported() throws {
        let recorder = UsageRecorder()
        let model = try model(recorder)
        model.nudge(caseId: "c1")
        model.copiedPrompt()
        #expect(recorder.records == [UsageRecord(.nudgeClicked), UsageRecord(.copyPromptClicked)])
    }
}
