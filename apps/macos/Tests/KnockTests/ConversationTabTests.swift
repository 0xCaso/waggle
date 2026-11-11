import Testing
import Foundation
@testable import Knock

/// C8: the Conversation tab's messages and words, its dot, its folding and the ⌘] routing; the Comments tab's dot.
/// The tab replaces the 380 pt conversation column (HAIL-71, WAG-299).
struct ConversationTabTests {
    private let utc = TimeZone(identifier: "UTC")!
    private func iso(_ hhmm: String) -> String { "2026-09-29T\(hhmm):00.000Z" }
    private func date(_ hhmm: String) -> Date { KnockDateFormat.date(from: iso(hhmm))! }

    private func twoRoundDetail(messages extra: [Message] = [], workingNote: String? = nil) -> CaseDetail {
        let c = Case(
            id: "c1", taskId: "t1", kind: .review, title: "Do the screens match?", need: "Review the screens.",
            why: "W", recommendation: "a", recommendationWhy: "RW",
            options: [Option(id: "a", label: "A · Approve"), Option(id: "b", label: "B · Changes needed")],
            status: workingNote == nil ? .needsYou : .waitingOnAgent, hasArtifact: true, workingNote: workingNote,
            taskName: "OME-534", project: "app", createdAt: iso("21:10"), updatedAt: iso("21:24"))
        let capture = Capture(id: "cap", revision: 1, pngBase64: "", annotatedPngBase64: "", takenAt: iso("21:23"), note: nil)
        let comment = Comment(id: "cm", captureId: "cap", n: 1, rect: Rect(x: 0, y: 0, w: 1, h: 1), text: "t")
        let reply = Reply(
            id: "r1", caseId: "c1", idempotencyKey: "r1", choice: "b", message: "Why both links?", comments: [comment],
            captures: [capture], intent: .decision, state: .delivered, createdAt: iso("21:23"), deliveredAt: iso("21:23"))
        return CaseDetail(
            case: c, task: KnockTask(id: "t1", name: "OME-534", project: "app"),
            messages: [Message(id: "m1", caseId: "c1", role: .agent, text: "They overlap.", createdAt: iso("21:24"))] + extra,
            revisions: [
                Revision(id: "v1", caseId: "c1", n: 1, createdAt: iso("21:10")),
                Revision(id: "v2", caseId: "c1", n: 2, createdAt: iso("21:24"))],
            comments: [comment], replies: [reply])
    }

    // MARK: Messages

    @Test func aFreshAskHasNoThreadButTheTabShowsTheAsk() {
        let d = twoRoundDetail()
        let one = CaseDetail(case: d.case, task: d.task, messages: [], revisions: d.revisions, comments: [], replies: [])
        #expect(one.threadModel() == nil)
        let conversation = one.conversationModel()
        #expect(conversation.steps.count == 1)
        guard case .asked(let asked) = conversation.steps[0] else { Issue.record("not the ask"); return }
        #expect(asked.need == "Review the screens.")
        #expect(asked.meta == "v1")
        #expect(conversation.roundCount == 1)
    }

    @Test func messageListIsAskReplyUpdateInOrder() throws {
        let model = twoRoundDetail().conversationModel()
        #expect(model.steps.count == 3)
        guard case .asked = model.steps[0], case .replied = model.steps[1], case .updated = model.steps[2] else {
            Issue.record("wrong order"); return
        }
        #expect(model.roundCount == 2)
        #expect(model.roundCount == 2)
    }

    @Test func headersUseTheDesignWords() throws {
        let model = try #require(twoRoundDetail().threadModel())
        guard case .asked(let asked) = model.steps[0], case .replied(let replied) = model.steps[1],
              case .updated(let updated) = model.steps[2] else { Issue.record("wrong steps"); return }
        #expect(ConversationCopy.askedHeader(asked, runtime: "Claude Code", timeZone: utc) == "CLAUDE CODE · 21:10")
        #expect(ConversationCopy.repliedHeader(replied, timeZone: utc) == "YOU · 21:23 · 1 comment on v1")
        #expect(ConversationCopy.updatedHeader(updated, runtime: "Claude Code", timeZone: utc) == "CLAUDE CODE · 21:24 · v2")
        #expect(ConversationCopy.pickedUpLine(try #require(replied.pickedUp), timeZone: utc) == "✓ picked up 21:23 · worked 1m")
    }

    @Test func turnLabelDropsTheHintWhileItIsYourTurn() {
        let yours = ThreadTurn(status: .needsYou, label: "Your turn: approve v2 or ask for changes", since: nil)
        #expect(ConversationCopy.turnLabel(yours) == "Your turn")
        let working = ThreadTurn(status: .working, label: "Claude Code is working", since: nil)
        #expect(ConversationCopy.turnLabel(working) == "Claude Code is working")
    }

    // MARK: Working notes fold to "Worked: N steps"

    @Test func backToBackProgressNotesFoldToOneRow() throws {
        let d = twoRoundDetail(messages: [
            Message(id: "m2", caseId: "c1", role: .agent, text: "Reading the screens", createdAt: iso("21:25"), working: true),
            Message(id: "m3", caseId: "c1", role: .agent, text: "Running the tests", createdAt: iso("21:26"), working: true),
            Message(id: "m4", caseId: "c1", role: .agent, text: "Done: v3 is up.", createdAt: iso("21:27")),
        ])
        let model = try #require(d.threadModel())
        let entries = ConversationRules.entries(model.steps)
        #expect(entries.count == 5)
        guard case .worked(let first, let notes) = entries[3] else { Issue.record("no worked row"); return }
        #expect(first == 3)
        #expect(notes.map(\.message) == ["Reading the screens", "Running the tests"])
        #expect(ConversationRules.workedLabel(notes.count) == "Worked: 2 steps")
        #expect(ConversationRules.workedLabel(1) == "Worked: 1 step")
        guard case .message(_, .updated(let last)) = entries[4] else { Issue.record("last is not the update"); return }
        #expect(last.message == "Done: v3 is up.")
    }

    @Test func theCaseWorkingNoteMarksItsMessageWhenTheDaemonSendsNoFlag() throws {
        let d = twoRoundDetail(
            messages: [Message(id: "m2", caseId: "c1", role: .agent, text: "Checking the build", createdAt: iso("21:25"))],
            workingNote: "Checking the build")
        let model = try #require(d.threadModel())
        guard case .updated(let note) = model.steps.last else { Issue.record("no update"); return }
        #expect(note.isWorking)
        guard case .updated(let earlier) = model.steps[2] else { Issue.record("no first update"); return }
        #expect(!earlier.isWorking)
    }

    // MARK: Message text

    @Test func theAgentQuestionLineIsShortAndStopsAtAList() {
        let parts = ConversationRules.parts("Do I open the PR now?\n- Waggle is closed.\n\nMore.", boldsQuestion: true)
        #expect(parts.question == "Do I open the PR now?")
        #expect(parts.details == "- Waggle is closed.\n\nMore.")
        let long = String(repeating: "word ", count: 60) + "end."
        #expect(ConversationRules.parts(long + "\n\nMore.", boldsQuestion: true).question.isEmpty)
        #expect(ConversationRules.parts("I will open the PR. Then I fix it.", boldsQuestion: true).question.isEmpty)
        #expect(ConversationRules.parts("Yes.\n\nMore.", boldsQuestion: false) == NeedText.Parts(question: "", details: "Yes.\n\nMore."))
    }

    // MARK: Latest message line and dot

    @Test func latestLineShowsTheNewestAgentMessageOffTheConversationTab() throws {
        let model = try #require(twoRoundDetail().threadModel())
        #expect(ConversationRules.latestLine(model, tab: .question, decisionHeadsWithIt: false)?.message == "They overlap.")
        #expect(ConversationRules.latestLine(model, tab: .comments, decisionHeadsWithIt: true)?.message == "They overlap.")
        #expect(ConversationRules.latestLine(model, tab: .conversation, decisionHeadsWithIt: false) == nil)
        #expect(ConversationRules.latestLine(model, tab: .question, decisionHeadsWithIt: true) == nil, "the page already heads with it")
        let askOnly = twoRoundDetail()
        let fresh = CaseDetail(case: askOnly.case, task: askOnly.task, messages: [], revisions: [], comments: [], replies: [])
        #expect(ConversationRules.latestLine(fresh.conversationModel(), tab: .question, decisionHeadsWithIt: false) == nil)
        #expect(ConversationRules.oneLine("**Hi** there.\n\nSecond `line`.") == "Hi there. Second line.")
    }

    @Test func dotShowsForAMessageNewerThanTheLastLook() {
        let at = date("21:24")
        #expect(ConversationDot.shows(latestAgentAt: at, seenAt: nil, tab: .question))
        #expect(ConversationDot.shows(latestAgentAt: at, seenAt: date("21:20"), tab: .comments))
        #expect(!ConversationDot.shows(latestAgentAt: at, seenAt: at, tab: .question))
        #expect(!ConversationDot.shows(latestAgentAt: at, seenAt: nil, tab: .conversation), "never while the tab is open")
        #expect(!ConversationDot.shows(latestAgentAt: nil, seenAt: nil, tab: .question), "no agent message, no dot")
    }

    @Test func latestAgentTimeCountsProgressNotes() throws {
        let d = twoRoundDetail(messages: [
            Message(id: "m2", caseId: "c1", role: .agent, text: "Working", createdAt: iso("21:30"), working: true)])
        #expect(ConversationDot.latestAgentAt(d.threadModel()) == date("21:30"))
        #expect(ConversationDot.latestAgentAt(nil) == nil)
    }

    @MainActor @Test func seenStoreKeepsTheNewestLook() throws {
        let suite = "conversation-seen-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConversationSeenStore(defaults: defaults)
        #expect(store.seenAt(caseId: "c1") == nil)
        store.markSeen(caseId: "c1", at: date("21:24"))
        store.markSeen(caseId: "c1", at: date("21:00"))
        #expect(store.seenAt(caseId: "c1") == date("21:24"), "an older look never moves it back")
        #expect(ConversationSeenStore(defaults: defaults).seenAt(caseId: "c1") == date("21:24"), "kept across launches")
    }

    // MARK: Routing

    @Test func commandBracketOpensConversationThenGoesBackToDecision() {
        #expect(ConversationTabRouting.toggled(.question) == .conversation)
        #expect(ConversationTabRouting.toggled(.comments) == .conversation)
        #expect(ConversationTabRouting.toggled(.conversation) == .question)
    }

    @Test func everyCaseOpensOnDecisionUnlessEvidenceAsks() {
        #expect(ConversationTabRouting.initialTab(environment: [:]) == .question)
        #expect(ConversationTabRouting.initialTab(environment: ["KNOCK_CONVERSATION_OPEN": "1"]) == .conversation)
        #expect(ConversationTabRouting.initialTab(environment: ["KNOCK_PANE_TAB": "comments"]) == .comments)
    }

    // MARK: Comments tab dot

    @Test func commentsDotShowsUnreadOrLateCommentsUntilTheTabIsOpened() {
        #expect(CommentsDot.shows(unreadAtOpen: 2, lateNew: 0, seen: false, tab: .question))
        #expect(CommentsDot.shows(unreadAtOpen: 0, lateNew: 1, seen: false, tab: .conversation))
        #expect(!CommentsDot.shows(unreadAtOpen: 2, lateNew: 1, seen: true, tab: .question))
        #expect(!CommentsDot.shows(unreadAtOpen: 2, lateNew: 0, seen: false, tab: .comments))
        #expect(!CommentsDot.shows(unreadAtOpen: 0, lateNew: 0, seen: false, tab: .question))
    }

    @Test func priorRevisionLinkWords() {
        let arrival = RevisionArrival(latestRevision: 2, priorRevision: 1, priorCommentCount: 3, agentMessage: nil)
        #expect(PriorRevisionCommentsLink.text(arrival) == "3 comments on v1 · view v1")
    }

    @Test func previewChipDropsTheVersionFromTheMeta() {
        #expect(ArtifactPreviewCard.metaWithoutVersion("v2 · still preview", revision: 2) == "still preview")
        #expect(ArtifactPreviewCard.metaWithoutVersion("v2", revision: 2) == "")
    }
}
