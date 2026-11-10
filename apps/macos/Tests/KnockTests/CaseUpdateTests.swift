import Testing
import Foundation
@testable import Knock

/// HAIL-67: an ask that came back after your reply says so, on the queue row,
/// in the ask pane and in the notification.
struct CaseUpdateTests {
    private let now = KnockDateFormat.date(from: "2026-09-29T10:10:00.000Z")!

    private func makeCase(
        status: CaseStatus = .needsYou, replyAt: String? = "2026-09-29T10:00:00.000Z",
        updateCount: Int? = 1, updateAt: String? = "2026-09-29T10:08:00.000Z",
        message: String? = "Rebuilt the screens\nfrom the design.", revisions: Int? = 1,
        revisionAt: String? = "2026-09-29T10:08:00.000Z"
    ) -> Case {
        Case(
            id: "c1", taskId: "t1", kind: .review, title: "Do the screens match?", need: "Confirm",
            why: "W", recommendation: "a", recommendationWhy: "RW",
            options: [Option(id: "a", label: "A · Yes"), Option(id: "b", label: "B · No")],
            status: status, hasArtifact: true,
            latestReplyId: replyAt == nil ? nil : "r1", latestReplyAt: replyAt, latestReplyChoice: "b", latestReplyMessage: "Not quite",
            updateCount: updateCount, latestUpdateAt: updateAt, latestUpdateMessage: message,
            revisionCount: revisions, latestRevisionAt: revisions == nil ? nil : revisionAt, taskName: "OME-534", project: "app",
            createdAt: "2026-09-29T09:00:00.000Z", updatedAt: "2026-09-29T10:08:00.000Z")
    }

    @Test func rowLineShowsForAnUpdateAfterYourReply() {
        let c = makeCase()
        #expect(c.pendingUpdate?.message == "Rebuilt the screens from the design.")
        #expect(c.pendingUpdate?.revision == nil)
    }

    @Test func rowsWithoutAnUpdateAreUnchanged() {
        #expect(makeCase(updateCount: 0, updateAt: nil, message: nil).pendingUpdate == nil)
        #expect(makeCase(updateCount: nil, updateAt: nil, message: nil).pendingUpdate == nil)
        // The update is older than your latest reply: you answered again.
        #expect(makeCase(replyAt: "2026-09-29T10:09:00.000Z").pendingUpdate == nil)
        // Not in Needs you: waiting on the agent again.
        #expect(makeCase(status: .waitingOnAgent).pendingUpdate == nil)
    }

    @Test func decodesWithoutTheNewFields() throws {
        let json = #"{"id":"c","task_id":"t","kind":"question","title":"T","need":"N","why":"W","recommendation":"a","recommendation_why":"R","options":[],"status":"needs_you","has_artifact":false,"created_at":"2026-09-29T09:00:00.000Z","updated_at":"2026-09-29T09:00:00.000Z"}"#
        let c = try JSONDecoder().decode(Case.self, from: Data(json.utf8))
        #expect(c.updateCount == nil && c.pendingUpdate == nil)
    }

    @Test func decodesTheNewFields() throws {
        let json = #"{"id":"c","task_id":"t","kind":"question","title":"T","need":"N","why":"W","recommendation":"a","recommendation_why":"R","options":[],"status":"needs_you","has_artifact":false,"update_count":2,"latest_update_at":"2026-09-29T10:08:00.000Z","latest_update_message":"Hi","revision_count":3,"created_at":"2026-09-29T09:00:00.000Z","updated_at":"2026-09-29T09:00:00.000Z"}"#
        let c = try JSONDecoder().decode(Case.self, from: Data(json.utf8))
        #expect(c.updateCount == 2 && c.latestUpdateMessage == "Hi" && c.revisionCount == 3)
    }

    @Test func notificationSaysUpdatedWithTheMessage() {
        let content = NotificationBuilder.updateContent(
            for: makeCase(), environment: [:], bundleIdentifier: TestCopyEnvironment.releaseBundleIdentifier)
        #expect(content?.title == "Updated: Do the screens match?")
        #expect(content?.body == "Rebuilt the screens")
        #expect(content?.identifier == "case.c1.update")
    }

    @Test func notificationRespectsTheHideQuestionSetting() {
        let content = NotificationBuilder.updateContent(
            for: makeCase(), showsQuestion: false, environment: [:],
            bundleIdentifier: TestCopyEnvironment.releaseBundleIdentifier)
        #expect(content?.title == "Your agent needs a decision")
        #expect(content?.body == "App")
    }

    @Test func noNotificationWithoutAnUpdate() {
        #expect(NotificationBuilder.updateContent(for: makeCase(updateCount: 0, updateAt: nil, message: nil)) == nil)
    }

    @MainActor @Test func onlyANewerUpdateNotifies() {
        let before = makeCase(status: .waitingOnAgent, updateCount: 0, updateAt: nil, message: nil)
        let after = makeCase()
        #expect(AppModel.isNewUpdate(after, before: [before]))
        // A dismiss and restore leave latest_update_at alone.
        #expect(!AppModel.isNewUpdate(after, before: [makeCase()]))
        // A case the app did not know is a new ask.
        #expect(!AppModel.isNewUpdate(after, before: []))
    }
}
