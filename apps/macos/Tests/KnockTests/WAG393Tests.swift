import Foundation
import Testing
@testable import Knock

/// WAG-394 (app side): the comment loop. Live reload, unread marks, threads, reply, resolve, the notification, close comments.
@MainActor
struct WAG393Tests {
    private func comment(
        _ id: String, _ body: String = "Hello", name: String = "Ada", kind: String = "member", parent: String? = nil,
        resolved: Bool = false, unread: Bool = false
    ) -> SharedComment {
        SharedComment(
            id: id, revision: 1, authorName: name, authorKind: kind, body: body, quote: nil, prefix: nil, suffix: nil, box: nil,
            createdAt: "2026-10-18T10:00:00.000Z", parentId: parent, resolvedAt: resolved ? "2026-10-18T11:00:00.000Z" : nil,
            resolvedBy: resolved ? "You" : nil, unread: unread)
    }

    private func state(
        _ comments: [SharedComment] = [], shared: Bool = true, closed: Bool = false, before: Bool = false
    ) -> SharingState {
        SharingState(
            enabled: true, sharedCount: shared ? 1 : 0, share: shared ? CaseShare(url: "u", mode: .link, emails: []) : nil,
            comments: comments, error: nil, commentsClosed: closed, sharedBefore: before)
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    // MARK: Decoding

    @Test func anOlderDaemonStillDecodes() throws {
        let s = try JSONDecoder().decode(SharingState.self, from: Data(
            #"{"enabled":true,"shared_count":1,"comments":[{"id":"a","author_name":"Ada","author_kind":"member","body":"x","created_at":"t"}],"error":null}"#.utf8))
        #expect(s.comments[0].parentId == nil)
        #expect(s.comments[0].resolvedAt == nil)
        #expect(!s.comments[0].unread)
        #expect(!s.commentsClosed)
        #expect(!s.sharedBefore)
    }

    @Test func theNewFieldsDecode() throws {
        let s = try JSONDecoder().decode(SharingState.self, from: Data("""
        {"enabled":true,"shared_count":1,"comments_closed":true,"shared_before":true,"error":null,
         "comments":[{"id":"b","author_name":"Claude","author_kind":"agent","body":"x","created_at":"t","parent_id":"a",
         "resolved_at":"r","resolved_by":"Ada","unread":true}]}
        """.utf8))
        #expect(s.commentsClosed && s.sharedBefore)
        #expect(s.comments[0].parentId == "a")
        #expect(s.comments[0].resolvedBy == "Ada")
        #expect(s.comments[0].unread)
    }

    @Test func anUnknownEventTypeDoesNotCrashTheDecoder() {
        let json = #"{"jsonrpc":"2.0","method":"event","params":{"type":"never.heard","at":"t"}}"#
        #expect((try? JSONDecoder().decode(JSONRPCNotification<Event>.self, from: Data(json.utf8))) == nil)
        #expect(EventType(rawValue: "comment.added") == .commentAdded)
    }

    // MARK: 1. Live reload

    @Test func anEventForTheOpenCaseReloadsItsModelAndTheNewCommentShows() async {
        let box = Box(state([comment("a")]))
        let model = SharingModel(caseId: "live-1", fetch: { box.value })
        SharingModels.register(model)
        await model.load()
        #expect(model.comments.count == 1)
        box.value = state([comment("a"), comment("b", "Second")])
        await SharingModels.reload(caseId: "live-1")
        #expect(model.comments.map(\.id) == ["a", "b"])
    }

    // MARK: 2. Unread marks

    @Test func theUnreadMapMarksRowsAndMarkSeenClearsIt() async {
        let map = Box<[String: Int]>([:])
        let server = Box([UnreadCase(caseId: "c1", count: 2)])
        let feed = TeamCommentsFeed(
            unread: { server.value },
            markSeen: { id in
                server.value.removeAll { $0.caseId == id }
                return server.value
            },
            take: { [] }, gate: { true }, notify: { _ in }, onUnread: { map.value = $0 })
        await feed.refreshUnread()
        #expect(map.value == ["c1": 2])
        await feed.markSeen(caseId: "c1")
        #expect(map.value.isEmpty)
    }

    @Test func aZeroCountIsNoMark() {
        #expect(TeamCommentsFeed.map([UnreadCase(caseId: "a", count: 0), UnreadCase(caseId: "b", count: 1)]) == ["b": 1])
    }

    // MARK: 3. Threads

    @Test func repliesGroupUnderTheirRoot() {
        let list = [
            comment("r1", "Root one"), comment("r2", "Root two"),
            comment("p1", "Agent reply", name: "Claude", kind: "agent", parent: "r1"),
            comment("p2", "Mine", name: "Simone", kind: "owner", parent: "r1"),
        ]
        let threads = CommentThreads.build(list)
        #expect(threads.map(\.id) == ["r1", "r2"])
        #expect(threads[0].replies.map(\.id) == ["p1", "p2"])
        #expect(threads[1].replies.isEmpty)
        #expect(CommentThreads.author(list[2]) == "Agent")
        #expect(CommentThreads.author(list[3]) == "You")
        #expect(CommentThreads.author(list[0]) == "Ada")
    }

    @Test func aReplyWithoutItsRootStillShows() {
        #expect(CommentThreads.build([comment("p", parent: "gone")]).map(\.id) == ["p"])
    }

    @Test func aResolvedThreadFoldsToOneLine() {
        let t = CommentThreads.build([comment("r", "Looks good\nSecond line", resolved: true)])[0]
        #expect(t.isResolved)
        #expect(CommentThreads.foldedLine(t) == "Resolved \u{00B7} Ada: Looks good")
    }

    // MARK: 4. Reply

    @Test func aReplySendsTheBodyToTheRootAndWorks() async {
        let sent = Box<[(String, String)]>([])
        let model = SharingModel(
            caseId: "c", fetch: { self.state([self.comment("r")]) },
            reply: { parent, body in
                sent.value.append((parent, body))
                return self.state([self.comment("r"), self.comment("p", body, kind: "owner", parent: parent)])
            })
        await model.load()
        let ok = await model.reply(to: "r", body: "  Thanks  ")
        #expect(ok)
        #expect(sent.value.count == 1 && sent.value[0].0 == "r" && sent.value[0].1 == "Thanks")
        #expect(model.threads[0].replies.count == 1)
        #expect(model.replyProblems["r"] == nil)
    }

    @Test func aFailedReplyKeepsTheTextAndShowsAPlainLine() async {
        let model = SharingModel(
            caseId: "c", fetch: { self.state([self.comment("r")]) },
            reply: { _, _ in throw JSONRPCErrorPayload(code: -32010, message: "Comments are closed.") })
        await model.load()
        let ok = await model.reply(to: "r", body: "Hi")
        #expect(!ok)
        #expect(model.replyProblems["r"] == "Comments are closed.")
    }

    @Test func anEmptyOrLongReplyIsNotSent() {
        #expect(!CommentThreads.canSend("  \n", busy: false, commentsClosed: false))
        #expect(!CommentThreads.canSend(String(repeating: "a", count: 4001), busy: false, commentsClosed: false))
        #expect(CommentThreads.canSend("ok", busy: false, commentsClosed: false))
        #expect(!CommentThreads.canSend("ok", busy: true, commentsClosed: false))
        #expect(!CommentThreads.canSend("ok", busy: false, commentsClosed: true))
    }

    // MARK: 5. Resolve and reopen

    @Test func resolveAndReopenCallTheDaemonWithTheFlag() async {
        let calls = Box<[(String, Bool)]>([])
        let model = SharingModel(
            caseId: "c", fetch: { self.state([self.comment("r")]) },
            resolve: { id, resolved in
                calls.value.append((id, resolved))
                return self.state([self.comment("r", resolved: resolved)])
            })
        await model.load()
        await model.resolve("r", resolved: true)
        #expect(model.threads[0].isResolved)
        await model.resolve("r", resolved: false)
        #expect(!model.threads[0].isResolved)
        #expect(calls.value.map(\.1) == [true, false])
        #expect(calls.value.allSatisfy { $0.0 == "r" })
    }

    // MARK: 6. Notification

    private let notice = TeamCommentNotice(
        caseId: "case-9", caseTitle: "Pricing page", commentId: "k1", authorName: "Ada", body: "**Looks** good\nSecond line")

    @Test func theNotificationHasTheTitleTheFirstLineAndTheCaseAsThread() {
        let c = NotificationBuilder.commentContent(for: notice, showsText: true, environment: [:], bundleIdentifier: "dev.limone.knock")
        #expect(c.title == "Ada commented on Pricing page")
        #expect(c.body == "Looks good")
        #expect(c.threadId == "case-9")
        #expect(c.caseId == "case-9")
    }

    @Test func withTheSettingOffTheNoticeHasFixedWordsAndNoCommentText() async {
        let posted = Box<[NotificationContent]>([])
        let shows = Box(false)
        let feed = TeamCommentsFeed(
            unread: { [] }, markSeen: { _ in [] }, take: { [self.notice] }, gate: { shows.value },
            notify: { posted.value.append($0) }, onUnread: { _ in }, environment: [:], bundleIdentifier: "dev.limone.knock")
        await feed.announce()
        #expect(posted.value.count == 1)
        let hidden = posted.value[0]
        #expect(hidden.title == "Your team commented on a case")
        #expect(hidden.body == "Open Waggle to read it.")
        #expect(!hidden.title.contains("Ada") && !hidden.title.contains("Pricing") && !hidden.body.contains("Looks"))
        #expect(hidden.threadId == "case-9")
        shows.value = true
        await feed.announce()
        #expect(posted.value.count == 2)
        #expect(posted.value[1].title == "Ada commented on Pricing page")
    }

    @Test func oneNotificationPerItem() async {
        let posted = Box<[NotificationContent]>([])
        let other = TeamCommentNotice(caseId: "case-9", caseTitle: "Pricing page", commentId: "k2", authorName: "Bo", body: "Hi")
        let feed = TeamCommentsFeed(
            unread: { [] }, markSeen: { _ in [] }, take: { [self.notice, other] }, gate: { true },
            notify: { posted.value.append($0) }, onUnread: { _ in }, environment: [:], bundleIdentifier: "dev.limone.knock")
        await feed.announce()
        #expect(posted.value.map(\.title) == ["Ada commented on Pricing page", "Bo commented on Pricing page"])
        #expect(Set(posted.value.map(\.identifier)).count == 2)
    }

    // MARK: 7. Close comments and the new link line

    @Test func closeCommentsCallsTheDaemonAndTheStateSaysSo() async {
        let calls = Box<[Bool]>([])
        let model = SharingModel(
            caseId: "c", fetch: { self.state([self.comment("r")]) },
            closeComments: { closed in
                calls.value.append(closed)
                return self.state([self.comment("r")], closed: closed)
            })
        await model.load()
        #expect(!model.commentsClosed)
        await model.setCommentsClosed(true)
        #expect(model.commentsClosed)
        #expect(calls.value == [true])
        #expect(TeamCommentCopy.closeTitle(closed: false) == "Close comments")
        #expect(TeamCommentCopy.closeTitle(closed: true) == "Open comments")
        #expect(TeamCommentCopy.closedLine == "Comments are closed.")
    }

    @Test func theNewLinkLineShowsOnlyForACaseSharedBeforeAndNotNow() {
        #expect(TeamCommentCopy.newLinkNote(shared: false, sharedBefore: true) == "This makes a new link. The old link stays off.")
        #expect(TeamCommentCopy.newLinkNote(shared: true, sharedBefore: true) == nil)
        #expect(TeamCommentCopy.newLinkNote(shared: false, sharedBefore: false) == nil)
    }

    @Test func noCopyHasAnEmDash() {
        for text in [TeamCommentCopy.closedLine, TeamCommentCopy.newLinkLine] { #expect(!text.contains("\u{2014}")) }
    }
}
