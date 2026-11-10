import Testing
import Foundation
@testable import Knock

private func revision(_ n: Int, at hhmm: String) -> Revision {
    Revision(id: "v\(n)", caseId: "c1", n: n, createdAt: "2026-09-29T\(hhmm):00.000Z")
}

/// HAIL-68: the ask thread built from messages, replies and revisions.
struct ThreadModelTests {
    private func iso(_ hhmm: String) -> String { "2026-09-29T\(hhmm):00.000Z" }

    private func makeCase(status: CaseStatus = .needsYou) -> Case {
        Case(
            id: "c1", taskId: "t1", kind: .review, title: "Do the screens match?", need: "Review the built screens.\nDo they match?",
            why: "W", recommendation: "a", recommendationWhy: "RW",
            options: [Option(id: "a", label: "A · Approve"), Option(id: "b", label: "B · Changes needed")],
            status: status, hasArtifact: true, taskName: "OME-534", project: "app",
            createdAt: iso("09:00"), updatedAt: iso("11:00"))
    }

    private func reply(_ id: String, at: String, choice: String? = "b", message: String? = "Fix the link",
                       comments: Int = 0, revision: Int = 1, delivered: String? = nil,
                       intent: ReplyIntent = .decision, format: ReplyFormat? = nil, state: ReplyStatus = .delivered) -> Reply {
        let capture = Capture(id: "cap\(id)", revision: revision, pngBase64: "", annotatedPngBase64: "", takenAt: iso(at), note: nil)
        let cs = (0..<comments).map {
            Comment(id: "cm\(id)\($0)", captureId: "cap\(id)", n: $0 + 1, rect: Rect(x: 0, y: 0, w: 1, h: 1), text: "t")
        }
        return Reply(
            id: id, caseId: "c1", idempotencyKey: id, choice: choice, message: message, comments: cs,
            captures: comments > 0 ? [capture] : [], intent: intent, format: format, state: state, createdAt: iso(at), deliveredAt: delivered.map(iso))
    }

    private func agent(_ id: String, at: String, _ text: String) -> Message {
        Message(id: id, caseId: "c1", role: .agent, text: text, createdAt: iso(at))
    }


    private func detail(
        status: CaseStatus = .needsYou, replies: [Reply], messages: [Message] = [], revisions: [Revision] = [revision(1, at: "09:00")]
    ) -> CaseDetail {
        let comments = replies.flatMap(\.comments)
        return CaseDetail(
            case: makeCase(status: status), task: KnockTask(id: "t1", name: "OME-534", project: "app"),
            messages: messages, revisions: revisions, comments: comments, replies: replies)
    }

    @Test func noReplyYetHasNoThread() {
        #expect(detail(replies: []).threadModel() == nil)
    }

    @Test func aDetailRequestKeepsAShortLeadAndTheFullQuestion() throws {
        let question = "What is a guide rule? I want to see an example before I pick."
        let withMessage = try #require(detail(replies: [
            reply("r1", at: "09:14", choice: nil, message: question, intent: .moreDetail)
        ]).threadModel())
        guard case .replied(let asked) = withMessage.steps[1] else { Issue.record("wrong step"); return }
        #expect(asked.summary == "Asked for more detail\n\n" + question)

        let bare = try #require(detail(replies: [
            reply("r1", at: "09:14", choice: nil, message: nil, intent: .moreDetail)
        ]).threadModel())
        guard case .replied(let plain) = bare.steps[1] else { Issue.record("wrong step"); return }
        #expect(plain.summary == "Asked for more detail")
    }

    /// HAIL-139: a detail request that named a format leads with it, and still
    /// keeps the human's question as its own paragraph.
    @Test func aDetailRequestWithAFormatLeadsWithIt() throws {
        let question = "Why don't we make the button blue?"
        let d = detail(replies: [
            reply("r1", at: "09:14", choice: nil, message: question, intent: .moreDetail, format: .diagram)
        ])
        guard case .replied(let asked) = try #require(d.threadModel()).steps[1] else { Issue.record("wrong step"); return }
        #expect(asked.summary == "Asked for more detail · as a diagram\n\n\(question)")

        let bare = try #require(detail(replies: [
            reply("r1", at: "09:14", choice: nil, message: nil, intent: .moreDetail, format: .eli5)
        ]).threadModel())
        guard case .replied(let plain) = bare.steps[1] else { Issue.record("wrong step"); return }
        #expect(plain.summary == "Asked for more detail · like I'm five")
    }

    @Test func oneRoundWithAnUpdateAndANewRevision() throws {
        let d = detail(
            replies: [reply("r1", at: "09:14", comments: 2, delivered: "09:14")],
            messages: [agent("m1", at: "09:22", "Fixed both.")],
            revisions: [revision(1, at: "09:00"), revision(2, at: "09:22")])
        let model = try #require(d.threadModel(artifactKind: .htmlBundle))
        #expect(model.steps.count == 3)
        guard case .asked(let asked) = model.steps[0], case .replied(let replied) = model.steps[1],
              case .updated(let updated) = model.steps[2] else { Issue.record("wrong step kinds"); return }
        #expect(asked.need == "Review the built screens. Do they match?")
        #expect(asked.meta == "v1 · Prototype")
        #expect(replied.summary == "Changes needed · Fix the link")
        #expect(replied.meta == "2 comments on v1")
        #expect(replied.pickedUp?.runtime == "Claude Code")
        #expect(abs((replied.pickedUp?.worked ?? 0) - 480) < 0.01)
        #expect(updated.message == "Fixed both.")
        #expect(updated.revision == .init(n: 2, isLatest: true, prior: 1))
        #expect(model.countLabel == "3 steps")
    }

    @Test func twoRoundsOrderByTime() throws {
        let d = detail(
            replies: [reply("r1", at: "09:14", delivered: "09:15"), reply("r2", at: "09:40", choice: "a", message: nil)],
            messages: [agent("m1", at: "09:22", "First."), agent("m2", at: "09:50", "Second.")],
            revisions: [revision(1, at: "09:00"), revision(2, at: "09:22")])
        let model = try #require(d.threadModel())
        let kinds = model.steps.map { step -> String in
            switch step { case .asked: "asked"; case .replied: "replied"; case .updated: "updated" }
        }
        #expect(kinds == ["asked", "replied", "updated", "replied", "updated"])
        // The second update brought no revision.
        guard case .updated(let second) = model.steps[4] else { return }
        #expect(second.revision == nil)
        guard case .replied(let secondReply) = model.steps[3] else { return }
        #expect(secondReply.summary == "Approve")
        #expect(secondReply.pickedUp == nil)
        // The first update's revision is the latest one made, marked latest.
        guard case .updated(let first) = model.steps[2] else { return }
        #expect(first.revision?.n == 2)
    }

    @Test func textOnlyUpdateHasNoRevisionChip() throws {
        let d = detail(replies: [reply("r1", at: "09:14")], messages: [agent("m1", at: "09:22", "No change to the screens.")])
        let model = try #require(d.threadModel())
        guard case .updated(let updated) = model.steps.last else { Issue.record("no update"); return }
        #expect(updated.revision == nil)
    }

    @Test func aRevisionMadeBeforeYourReplyIsNotNew() throws {
        let d = detail(
            replies: [reply("r1", at: "09:14")], messages: [agent("m1", at: "09:22", "Text only.")],
            revisions: [revision(1, at: "09:00"), revision(2, at: "09:10")])
        guard case .updated(let updated)? = try #require(d.threadModel()).steps.last else { Issue.record("no update"); return }
        #expect(updated.revision == nil)
    }

    @Test func anAgentMessageBeforeYourFirstReplyIsNotAStep() throws {
        let d = detail(replies: [reply("r1", at: "09:14")], messages: [agent("m0", at: "09:05", "Early note.")])
        #expect(try #require(d.threadModel()).steps.count == 2)
    }

    @Test func aSupersededReplyIsLeftOut() throws {
        let d = detail(replies: [reply("r0", at: "09:10", state: .superseded), reply("r1", at: "09:14")])
        #expect(try #require(d.threadModel()).steps.count == 2)
    }

    @Test func expansionIsRememberedPerAsk() async {
        await MainActor.run {
            let store = ThreadExpansionStore(environment: [:])
            #expect(!store.isExpanded("c1"))
            store.toggle("c1")
            #expect(store.isExpanded("c1") && !store.isExpanded("c2"))
            store.toggle("c1")
            #expect(!store.isExpanded("c1"))
            #expect(ThreadExpansionStore(environment: ["KNOCK_THREAD_EXPANDED": "1"]).isExpanded("c9"))
        }
    }

    @Test func currentTurnWhenItNeedsYou() throws {
        let d = detail(
            replies: [reply("r1", at: "09:14")], messages: [agent("m1", at: "09:22", "Fixed.")],
            revisions: [revision(1, at: "09:00"), revision(2, at: "09:22")])
        let model = try #require(d.threadModel())
        let turn = d.threadTurn(model)
        #expect(turn.status == .needsYou)
        #expect(turn.label == "Your turn: approve v2 or ask for changes")
        #expect(turn.since == KnockDateFormat.date(from: iso("09:22")))
    }

    @Test func currentTurnOfAnAnsweredAskIsSettledWithNoTimer() throws {
        let d = detail(replies: [reply("r1", at: "09:14")], messages: [], revisions: [])
        let model = try #require(d.threadModel())
        let settled = AnswerGrouping.Settled(pickedUpAt: nil, followUp: nil)
        let turn = d.threadTurn(model, settled: settled)
        #expect(turn.status == .closed)
        #expect(turn.label == "Not picked up")
        #expect(turn.since == nil)
    }

    @Test func currentTurnWhileTheAgentWorks() throws {
        var d = detail(status: .waitingOnAgent, replies: [reply("r1", at: "09:14", delivered: "09:15")])
        d = CaseDetail(case: Case(
            id: "c1", taskId: "t1", kind: .review, title: "T", need: "N", why: "W", recommendation: "a", recommendationWhy: "R",
            options: [], status: .waitingOnAgent, hasArtifact: true, latestReplyState: .delivered,
            latestReplyAt: iso("09:14"), latestReplyDeliveredAt: iso("09:15"), taskName: "OME-534", project: "app",
            createdAt: iso("09:00"), updatedAt: iso("09:15")),
            task: d.task, messages: d.messages, revisions: d.revisions, comments: d.comments, replies: d.replies)
        let model = try #require(d.threadModel())
        let turn = d.threadTurn(model)
        #expect(turn.status == .working)
        #expect(turn.label == "Claude Code is working on your reply")
        #expect(turn.since == KnockDateFormat.date(from: iso("09:15")))
    }

    @Test func copy() {
        #expect(ThreadCopy.worked(45) == "worked 45s")
        #expect(ThreadCopy.worked(8 * 60) == "worked 8m")
        #expect(ThreadCopy.worked(3600 + 5 * 60) == "worked 1h 5m")
        #expect(ThreadCopy.clock(Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!) == "00:00")
        #expect(ThreadCopy.yourTurn(kind: .question, newRevision: nil) == "pick an option or reply")
    }
}
