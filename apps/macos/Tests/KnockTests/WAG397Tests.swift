import Foundation
import Testing
@testable import Knock

/// WAG-397: one Comments tab. Your notes to the agent and the team thread from the page in one list, labels,
/// the switch in the composer, the count line in the Decision tab, and the notice that opens the tab.
@MainActor
struct WAG397Tests {
    private func shared(
        _ id: String, _ body: String = "Hello", kind: String = "member", at: String = "2026-10-18T10:00:00.000Z",
        parent: String? = nil, unread: Bool = false
    ) -> SharedComment {
        SharedComment(
            id: id, revision: 1, authorName: kind == "agent" ? "Agent" : "Ada", authorKind: kind, body: body, quote: nil,
            prefix: nil, suffix: nil, box: nil, createdAt: at, parentId: parent, unread: unread)
    }

    private func note(_ id: String, n: Int) -> CommentRow {
        CommentRow(
            comment: Comment(id: id, captureId: "cap", n: n, rect: Rect(x: 0, y: 0, w: 1, h: 1), text: "Note \(n)"),
            anchorLabel: "region", state: .saved, placement: .onView)
    }

    private func state(_ comments: [SharedComment] = [], shared isShared: Bool = true, enabled: Bool = true, closed: Bool = false) -> SharingState {
        SharingState(
            enabled: enabled, sharedCount: isShared ? 1 : 0, share: isShared ? CaseShare(url: "u", mode: .link, emails: []) : nil,
            comments: comments, error: nil, commentsClosed: closed)
    }

    private final class Calls: @unchecked Sendable {
        var comments: [String] = []
        var replies: [String] = []
    }

    // MARK: Merged list: order and labels

    @Test func theListHoldsTheThreadsOldestFirstThenYourNotes() {
        let late = CommentThread(root: shared("t2", at: "2026-10-18T12:00:00.000Z"), replies: [])
        let early = CommentThread(root: shared("t1", at: "2026-10-18T09:00:00.000Z"), replies: [shared("r1", kind: "agent", parent: "t1")])
        let entries = MergedComments.entries(local: [note("n2", n: 2), note("n1", n: 1)], threads: [late, early])
        #expect(entries.map(\.id) == ["thread-t1", "thread-t2", "local-n1", "local-n2"])
    }

    @Test func eachKindOfCommentHasItsLabel() {
        #expect(MergedComments.label(shared("a", kind: "member")) == "Team")
        #expect(MergedComments.label(shared("b", kind: "guest")) == "Team")
        #expect(MergedComments.label(shared("c", kind: "agent")) == "Agent")
        #expect(MergedComments.label(shared("d", kind: "owner")) == "You \u{00B7} on the page")
        #expect(MergedComments.youLabel == "You")
    }

    @Test func labelsShowOnlyForASharedCaseOrWhenTheTeamWrote() {
        let thread = CommentThread(root: shared("t1"), replies: [])
        #expect(!MergedComments.showsLabels(isShared: false, threads: []))
        #expect(MergedComments.showsLabels(isShared: true, threads: []))
        #expect(MergedComments.showsLabels(isShared: false, threads: [thread]))
    }

    @Test func theSharedEmptyLineNamesBothKindsWithoutEmDashes() {
        #expect(MergedComments.sharedEmptyLine == "No comments yet. Your team comments on the page; you can write to the agent or on the page below.")
        #expect(!MergedComments.sharedEmptyLine.contains("\u{2014}"))
    }

    // MARK: The switch

    @Test func theSwitchShowsOnlyWhileTheCaseIsSharedAndSharingIsOn() async {
        func canWrite(_ s: SharingState) async -> Bool {
            let model = SharingModel(caseId: "sw", fetch: { s })
            await model.load()
            return model.canWriteOnPage
        }
        #expect(await canWrite(state()))
        #expect(await !canWrite(state(shared: false)))
        #expect(await !canWrite(state(enabled: false)))
    }

    @Test func theDefaultIsToTheAgentAndTheTargetFallsBackWhenNotShared() {
        var chosen = MergedComments.Target.agent
        #expect(MergedComments.effectiveTarget(chosen, canWriteOnPage: true) == .agent)
        chosen = .page
        #expect(MergedComments.effectiveTarget(chosen, canWriteOnPage: true) == .page)
        #expect(MergedComments.effectiveTarget(chosen, canWriteOnPage: false) == .agent)
        #expect(MergedComments.title(.agent) == "To the agent")
        #expect(MergedComments.title(.page) == "On the page")
    }

    @Test func thePlaceholderSaysWhereTheTextGoes() {
        #expect(MergedComments.placeholder(.agent) == "Write to the agent. Your team does not see it.")
        #expect(MergedComments.placeholder(.page) == "Write on the page. Your team sees it.")
    }

    // MARK: Post target

    @Test func aPostOnThePageGoesToTheCommentCallAndNotToAReply() async {
        let calls = Calls()
        let posted = state([shared("o1", "Note for the team", kind: "owner")])
        let model = SharingModel(
            caseId: "post-1", fetch: { posted },
            reply: { _, body in calls.replies.append(body); return posted },
            comment: { body in calls.comments.append(body); return posted })
        await model.load()
        let ok = await model.commentOnPage("  Note for the team  ")
        #expect(ok)
        #expect(calls.comments == ["Note for the team"])
        #expect(calls.replies.isEmpty)
        #expect(model.comments.map(\.id) == ["o1"])
    }

    @Test func anEmptyPostOrAClosedPageMakesNoCall() async {
        let calls = Calls()
        let closed = state(closed: true)
        let model = SharingModel(caseId: "post-2", fetch: { closed }, comment: { body in calls.comments.append(body); return closed })
        await model.load()
        #expect(await !model.commentOnPage("   "))
        #expect(await !model.commentOnPage("late"))
        #expect(model.pageProblem == "Comments are closed.")
        #expect(calls.comments.isEmpty)
    }

    @Test func aFailedPostKeepsTheTextAndSaysWhy() async {
        struct Down: Error {}
        let model = SharingModel(caseId: "post-3", fetch: { SharingState.off }, comment: { _ in throw Down() })
        let ok = await model.commentOnPage("hello")
        #expect(!ok)
        #expect(model.pageProblem != nil)
        #expect(!model.posting)
    }

    // MARK: Count line

    @Test func theCountLineCountsTheTeamAndTheNewOnes() {
        let comments = [
            shared("a", unread: true), shared("b", kind: "guest"), shared("c", parent: "a"),
            shared("d", kind: "agent", parent: "a"), shared("e", kind: "owner", parent: "a"),
        ]
        #expect(MergedComments.countLine(comments) == "3 team comments, 1 new")
    }

    @Test func theCountLineHandlesOneNoneAndAllSeen() {
        #expect(MergedComments.countLine([]) == nil)
        #expect(MergedComments.countLine([shared("a", kind: "agent")]) == nil)
        #expect(MergedComments.countLine([shared("a")]) == "1 team comment")
        #expect(MergedComments.countLine([shared("a", unread: true)]) == "1 team comment, 1 new")
    }

    // MARK: The notice opens the Comments tab

    @Test func aTeamCommentNoticeOpensTheCommentsTab() {
        let notice = TeamCommentNotice(caseId: "c9", caseTitle: "Pricing", commentId: "k1", authorName: "Ada", body: "Hi")
        let content = NotificationBuilder.commentContent(for: notice, showsText: true, environment: [:], bundleIdentifier: "dev.limone.knock")
        #expect(content.opensComments)
        #expect(content.caseId == "c9")
    }

    @Test func otherNoticesDoNotChangeTheirTab() {
        let content = NotificationContent(identifier: "i", caseId: "c", title: "t", subtitle: "", body: "b")
        #expect(!content.opensComments)
    }
}
