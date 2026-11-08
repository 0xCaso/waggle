import Testing
import Foundation
import AppKit
import SwiftUI
@testable import Knock

/// WAG-357: comments on the text of a request.
@MainActor
struct AskTextCommentTests {
    private func anchor(_ part: AskTextPart = .title, quote: String = "words", start: Int = 0, end: Int = 5) -> AskTextAnchor {
        AskTextAnchor(part: part, quote: quote, start: start, end: end)
    }

    private func face() -> AskTextFace {
        AskTextFace(style: Theme.AskDoc.Typography.optionCard13, color: .black)
    }

    private func book() -> SourceBook {
        SourceBook(sources: [Source(id: "s1", kind: "file", label: "a.ts:1"), Source(id: "s2", kind: "file", label: "b.ts:2")])
    }

    // MARK: Anchor

    @Test func theNewAnchorEncodesUnderAnchorWithItsKind() throws {
        let comment = Knock.Comment(id: "c1", n: 1, askAnchor: AskTextAnchor(part: .pro, optionId: "a", quote: "Fast", start: 0, end: 4), text: "Really?")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(comment)) as! [String: Any]
        #expect(json["capture_id"] == nil && json["rect"] == nil)
        let wire = json["anchor"] as! [String: Any]
        #expect(wire["kind"] as? String == "ask_text")
        #expect(wire["part"] as? String == "pro" && wire["option_id"] as? String == "a")
        #expect(wire["item_id"] == nil && wire["source_id"] == nil)
        #expect(wire["quote"] as? String == "Fast" && wire["start"] as? Int == 0 && wire["end"] as? Int == 4)
    }

    @Test func bothAnchorKindsDecodeFromTheAnchorField() throws {
        let old = Data(#"{"id":"c1","n":1,"text":"t","anchor":{"kind":"text","revision":2,"quote":"abc","start":0,"end":3}}"#.utf8)
        let oldComment = try JSONDecoder().decode(Knock.Comment.self, from: old)
        #expect(oldComment.isText && !oldComment.isAsk && oldComment.anchor?.revision == 2)
        let new = Data(#"{"id":"c2","n":2,"text":"t","anchor":{"kind":"ask_text","part":"question","item_id":"q1","quote":"Which?","start":4,"end":10}}"#.utf8)
        let newComment = try JSONDecoder().decode(Knock.Comment.self, from: new)
        #expect(newComment.isAsk && !newComment.isText && newComment.askAnchor?.part == .question && newComment.askAnchor?.itemId == "q1")
        #expect(newComment.captureId == "" && newComment.hasNoCapture)
        let again = try JSONDecoder().decode(Knock.Comment.self, from: JSONEncoder().encode(newComment))
        #expect(again == newComment)
    }

    @Test func aRegionCommentStaysAsItWas() throws {
        let data = Data(#"{"id":"c","capture_id":"cap","n":1,"rect":{"x":0.1,"y":0.2,"w":0.3,"h":0.4},"text":"t"}"#.utf8)
        let comment = try JSONDecoder().decode(Knock.Comment.self, from: data)
        #expect(!comment.isAsk && !comment.hasNoCapture && comment.captureId == "cap")
    }

    // MARK: Offsets

    @Test func offsetsCountPlainTextWithoutMarkdownMarks() {
        let content = AskTextContent.build(text: "Both **repeat buyers** and `code` pass", mode: .line, face: face(), book: nil, showsPills: false)
        #expect(content.plain == "Both repeat buyers and code pass")
        let start = (content.plain as NSString).range(of: "repeat buyers")
        let rendered = content.renderedRange(forPlain: start.location..<(start.location + start.length))
        #expect(rendered != nil)
        #expect(content.attributed.string == content.plain)
        #expect(content.plainRange(forRendered: rendered!) == start.location..<(start.location + start.length))
        #expect(content.quote(forPlain: start.location..<(start.location + start.length)) == "repeat buyers")
    }

    @Test func sourceMarkersAreNotInThePlainTextAndPillsTakeNoOffset() {
        let text = "Compact is faster.[[s:s1]] Detailed explains tiers.[[s:s2]]"
        let content = AskTextContent.build(text: text, mode: .line, face: face(), book: book(), showsPills: true)
        #expect(content.plain == "Compact is faster. Detailed explains tiers.")
        #expect(content.pills.count == 2)
        // The attributed string holds one attachment character per pill.
        #expect(content.attributed.length == content.plain.utf16.count + 2)
        let tiers = (content.plain as NSString).range(of: "tiers")
        let rendered = content.renderedRange(forPlain: tiers.location..<(tiers.location + tiers.length))!
        #expect(content.plainRange(forRendered: rendered) == tiers.location..<(tiers.location + tiers.length))
        // A selection that covers a pill and words gives the words' range.
        let all = content.plainRange(forRendered: 0..<content.attributed.length)
        #expect(all == 0..<content.plain.utf16.count)
        // With no pills the markers are gone and the text is the same.
        let flat = AskTextContent.build(text: text, mode: .line, face: face(), book: nil, showsPills: false)
        #expect(flat.plain == content.plain && flat.pills.isEmpty)
    }

    @Test func aMarkerThatNamesNoSourceDrawsNothing() {
        let content = AskTextContent.build(text: "Words.[[s:nope]] More.", mode: .line, face: face(), book: book(), showsPills: true)
        #expect(content.plain == "Words. More." && content.pills.isEmpty)
    }

    @Test func blocksKeepTheBreakAndLeaveBulletsOutOfThePlainText() {
        let content = AskTextContent.build(text: "First line.\n\n- one\n- two[[s:s1]]", mode: .blocks, face: face(), book: book(), showsPills: true)
        #expect(content.plain == "First line.\none\ntwo")
        let two = (content.plain as NSString).range(of: "two")
        let rendered = content.renderedRange(forPlain: two.location..<(two.location + two.length))!
        #expect(content.plainRange(forRendered: rendered) == two.location..<(two.location + two.length))
        // A selection that is only a bullet holds no plain text.
        let bullet = (content.attributed.string as NSString).range(of: "•")
        #expect(content.plainRange(forRendered: bullet.location..<(bullet.location + 1)) == nil)
    }

    @Test func plainLengthAndLineBasesMatchWhatTheViewsShow() {
        #expect(AskTextContent.plainLength(of: "Some **bold** text[[s:s1]]", mode: .line) == "Some bold text".utf16.count)
        #expect(AskTextContent.lineBases(["ab", "**cd**", "e"]) == [0, 3, 6])
    }

    @Test func aTargetAddsItsBaseOffsetToTheAnchor() {
        let target = AskCommentTarget(.source, sourceId: "s1", slot: "note", baseOffset: 10)
        let made = target.anchor(quote: "q", start: 2, end: 5)
        #expect(made.start == 12 && made.end == 15 && made.sourceId == "s1" && made.part == .source)
        #expect(target.owns(made))
        #expect(!AskCommentTarget(.source, sourceId: "s2").owns(made))
        #expect(!AskCommentTarget(.pro, sourceId: "s1").owns(made))
    }

    // MARK: Numbers, store, restore

    @Test func numbersRunThroughArtifactAndRequestComments() {
        var model = CommentsModel()
        let capture = model.addCapture(revision: 1)
        model.addComment(captureId: capture.id, rect: Rect(x: 0, y: 0, w: 1, h: 1), text: "pin")
        let ask = model.addAskComment(anchor: anchor(), text: "on the title")
        model.addTextComment(anchor: TextAnchor(revision: 1, quote: "x", start: 0, end: 1), text: "span")
        let second = model.addAskComment(anchor: anchor(.why), text: "on the why")
        #expect(model.orderedComments.map(\.n) == [1, 2, 3, 4])
        #expect(ask.n == 2 && second.n == 4)
        #expect(model.askComments.map(\.text) == ["on the title", "on the why"])
        model.deleteComment(id: ask.id)
        #expect(model.orderedComments.map(\.n) == [1, 2, 3])
        #expect(model.askComments.first?.n == 3 && model.askComments.first?.askAnchor?.part == .why)
        model.updateCommentText(id: second.id, text: "edited")
        #expect(model.askComments.first?.askAnchor?.part == .why && model.askComments.first?.text == "edited")
    }

    @Test func theStoreRefusesAnEmptyNoteAndCountsTheComment() {
        let store = CommentsSessionStore()
        #expect(store.addAskComment(anchor: anchor(), text: "   ") == nil)
        let saved = store.addAskComment(anchor: anchor(), text: " Shorter. ")
        #expect(saved?.text == "Shorter." && saved?.n == 1)
        #expect(store.nextPinNumber == 2)
    }

    @Test func aNewRoundClearsRequestCommentsThatWereNotSent() {
        let store = CommentsSessionStore()
        store.addAskComment(anchor: anchor(), text: "one")
        store.addAskComment(anchor: anchor(.need), text: "two")
        #expect(store.model.comments.count == 2)
        store.clearComments()
        #expect(store.model.comments.isEmpty)
    }

    @Test func aPendingReplySavesAndRestoresRequestComments() throws {
        let comments = [
            Knock.Comment(id: "a1", n: 1, askAnchor: AskTextAnchor(part: .recommendation, itemId: "q", optionId: "a", quote: "Compact", start: 0, end: 7), text: "Why?"),
            Knock.Comment(id: "a2", n: 2, anchor: TextAnchor(revision: 1, quote: "x", start: 0, end: 1), text: "span"),
        ]
        let home = NSTemporaryDirectory() + UUID().uuidString
        let pending = PendingReply(caseId: "c_1", idempotencyKey: "k", choice: "a", message: nil, comments: comments, captures: [])
        let pendingStore = PendingReplyStore(environment: ["KNOCK_HOME": home])
        try pendingStore.save(pending)
        let loaded = try #require(pendingStore.load(caseId: "c_1"))
        #expect(loaded.comments == comments)
        #expect(loaded.comments[0].askAnchor?.optionId == "a")

        let reply = Reply(
            id: "r", caseId: "c_1", idempotencyKey: "k", choice: "a", message: nil, comments: loaded.comments, captures: [],
            intent: .decision, format: nil, source: .mac, state: .queued, createdAt: "2026-10-10T10:00:00.000Z", replacedAt: nil,
            deliveredAt: nil, choices: nil)
        let store = CommentsSessionStore()
        store.restore(from: reply)
        #expect(store.model.orderedComments.map(\.id) == ["a1", "a2"])
        #expect(store.model.askComments.first?.askAnchor == comments[0].askAnchor)
        #expect(ReplyPayloadBuilder.build(model: store.model, imagesByCaptureId: [:]).comments.map(\.id) == ["a1", "a2"])
    }

    @Test func theSendButtonCountsRequestCommentsWithTheOthers() {
        let store = CommentsSessionStore()
        store.addAskComment(anchor: anchor(), text: "one")
        store.addAskComment(anchor: anchor(.why), text: "two")
        let count = store.model.comments.count
        #expect(count == 2)
        #expect(PromptBarLogic.sendPillLabel(commentCount: count) == "Send + 2 comments")
        #expect(PromptBarLogic.sendPillLabel(commentCount: 1) == "Send + 1 comment")
    }

    // MARK: The hub

    @Test func theHubGivesEachTextOnlyItsOwnComments() {
        let store = CommentsSessionStore()
        let hub = AskCommentsHub(store: store)
        store.addAskComment(anchor: AskTextAnchor(part: .pro, optionId: "a", quote: "Fast", start: 0, end: 4), text: "pro a")
        store.addAskComment(anchor: AskTextAnchor(part: .pro, optionId: "b", quote: "Fast", start: 0, end: 4), text: "pro b")
        store.addAskComment(anchor: AskTextAnchor(part: .source, sourceId: "s1", quote: "tail", start: 20, end: 24), text: "src")
        #expect(hub.comments(for: AskCommentTarget(.pro, optionId: "a"), length: 10).map(\.text) == ["pro a"])
        #expect(hub.comments(for: AskCommentTarget(.title), length: 10).isEmpty)
        // A source shows in three views; each owns the range that falls inside it.
        #expect(hub.comments(for: AskCommentTarget(.source, sourceId: "s1", baseOffset: 18), length: 10).map(\.text) == ["src"])
        #expect(hub.comments(for: AskCommentTarget(.source, sourceId: "s1", baseOffset: 0), length: 10).isEmpty)
    }

    @Test func sentCommentsShowReadOnlyAndDoNotDouble() {
        let store = CommentsSessionStore()
        let hub = AskCommentsHub(store: store, canComment: false)
        let sent = Knock.Comment(id: "x", n: 1, askAnchor: anchor(), text: "sent")
        hub.setSent([sent, Knock.Comment(id: "y", n: 2, anchor: TextAnchor(revision: 1, quote: "q", start: 0, end: 1), text: "span")])
        #expect(hub.allComments.map(\.id) == ["x"])
        #expect(!hub.isPending("x"))
        // Change answer puts the sent comment back in the store: it shows once.
        store.restore(from: Reply(
            id: "r", caseId: "c", idempotencyKey: "k", choice: nil, message: "m", comments: [sent], captures: [], intent: .decision,
            format: nil, source: .mac, state: .queued, createdAt: "2026-10-10T10:00:00.000Z", replacedAt: nil, deliveredAt: nil, choices: nil))
        #expect(hub.allComments.map(\.id) == ["x"] && hub.isPending("x"))
    }

    @Test func onlyRepliesOfTheRoundCount() {
        func reply(_ id: String, at: String, replaced: String? = nil) -> Reply {
            Reply(
                id: id, caseId: "c", idempotencyKey: id, choice: nil, message: "m",
                comments: [Knock.Comment(id: "k\(id)", n: 1, askAnchor: anchor(), text: id)], captures: [], intent: .decision, format: nil,
                source: .mac, state: .delivered, createdAt: at, replacedAt: replaced, deliveredAt: nil, choices: nil)
        }
        let start = KnockDateFormat.date(from: "2026-10-10T10:00:00.000Z")
        let replies = [
            reply("old", at: "2026-10-10T09:00:00.000Z"), reply("new", at: "2026-10-10T10:30:00.000Z"),
            reply("gone", at: "2026-10-10T10:40:00.000Z", replaced: "2026-10-10T10:41:00.000Z"),
        ]
        #expect(AskCommentsRound.comments(replies: replies, roundStart: start).map(\.text) == ["new"])
        #expect(AskCommentsRound.comments(replies: replies, roundStart: nil).map(\.text) == ["old", "new"])
    }

    // MARK: Where it works

    @Test func aSelectionInTwoPartsGivesNoCommentButton() {
        typealias P = AskSelectionRule.PartSelection
        #expect(AskSelectionRule.single([P(key: "title", hasSelection: true), P(key: "need", hasSelection: false)]) == "title")
        #expect(AskSelectionRule.single([P(key: "title", hasSelection: true), P(key: "need", hasSelection: true)]) == nil)
        #expect(AskSelectionRule.single([P(key: "title", hasSelection: false)]) == nil)
    }

    @Test func theHubShowsTheButtonForOneSelectionAndNotForTwo() {
        let hub = AskCommentsHub(store: CommentsSessionStore())
        let a = AskCommentTextView.make(), b = AskCommentTextView.make()
        let titleContent = AskTextContent.build(text: "The title words", mode: .line, face: face(), book: nil, showsPills: false)
        a.configure(content: titleContent, target: AskCommentTarget(.title), comments: [], selectedId: nil, canComment: true, hub: hub, sourcesHub: nil)
        b.configure(content: titleContent, target: AskCommentTarget(.why), comments: [], selectedId: nil, canComment: true, hub: hub, sourcesHub: nil)
        a.setSelectedRange(NSRange(location: 4, length: 5))
        #expect(hub.ui.selection?.target.part == .title && hub.ui.selection?.anchor.quote == "title")
        // A second selection in another part clears the first one: never two parts at once.
        hub.willSelect(in: b)
        b.setSelectedRange(NSRange(location: 0, length: 3))
        #expect(a.selectedRange().length == 0)
        #expect(hub.ui.selection?.target.part == .why)
        // Sent answer: nothing can be selected for a comment.
        hub.canComment = false
        b.configure(content: titleContent, target: AskCommentTarget(.why), comments: [], selectedId: nil, canComment: false, hub: hub, sourcesHub: nil)
        #expect(hub.ui.selection == nil)
    }

    @Test func optionRowsAndLabelsTakeNoComment() {
        // The text of an option row is built with no target, so it is not a commentable text.
        #expect(GoodWatchOutView(pros: ["a"], cons: ["b"]).commentIds == nil)
        #expect(CalmNoteView(title: "Why", text: "t").target == nil)
        #expect(SourcedText(text: "t", style: Theme.AskDoc.Typography.optionCard13, color: .black).target == nil)
        #expect(AgentMarkdownText(text: "t").target == nil)
        #expect(YourPickBlockView(label: "L", title: "T", swapId: "x").commentIds == nil)
        // Waggle's own words are never part of a plain text.
        let why = AskTextContent.build(text: "Because.", mode: .line, face: face(), book: nil, showsPills: false, prefix: "Why you:")
        #expect(why.plain == "Because." && why.attributed.string == "Why you: Because.")
        #expect(why.plainRange(forRendered: 0..<8) == nil)
    }

    @Test func aNoteNamesThePartInPlainWords() {
        #expect(AskTextPart.allCases.map(\.words) == [
            "the title", "what I need", "the why", "the question", "the recommendation", "a pro", "a con", "an effect", "a source",
        ])
        #expect(AskTextPart.title.onWords == "On the title")
        let row = CommentRow(
            comment: Knock.Comment(id: "c", n: 1, askAnchor: anchor(.need), text: "t"), anchorLabel: "", state: .saved, placement: .onView)
        #expect(!row.isOffView)
        #expect(CommentAnchorLabel.make(comment: row.comment, model: CommentsModel(), isScreenshotsCase: false) == "On what I need")
    }

    @Test func thePopoverAndButtonStayInsideTheHost() {
        let host = CGSize(width: 800, height: 600)
        let near = AskPlacement.origin(anchor: CGRect(x: 780, y: 100, width: 0, height: 20), size: CGSize(width: 252, height: 120), host: host)
        #expect(abs(near.x - 544) < 0.01)
        #expect(abs(near.y - 118) < 0.01)
        let low = AskPlacement.origin(anchor: CGRect(x: 100, y: 560, width: 0, height: 20), size: CGSize(width: 252, height: 120), host: host)
        #expect(low.y < 560)
    }
}
