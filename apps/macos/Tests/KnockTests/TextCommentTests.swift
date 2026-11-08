import Testing
import Foundation
@testable import Knock

/// HAIL-150: comments on a range of a markdown revision's source.
@MainActor
struct TextCommentTests {
    private let anchor = TextAnchor(revision: 1, quote: "grows without limit", start: 12, end: 31)

    @Test func textCommentEncodesWithoutCaptureOrRect() throws {
        let comment = Knock.Comment(id: "c1", n: 1, anchor: anchor, text: "Too absolute.")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(comment)) as! [String: Any]
        #expect(json["capture_id"] == nil)
        #expect(json["rect"] == nil)
        let wire = json["anchor"] as! [String: Any]
        #expect(wire["kind"] as? String == "text")
        #expect(wire["quote"] as? String == "grows without limit")
        #expect(wire["start"] as? Int == 12 && wire["end"] as? Int == 31 && wire["revision"] as? Int == 1)
    }

    @Test func textCommentDecodesAndRoundTrips() throws {
        let data = Data(#"{"id":"c1","n":2,"text":"Hm","anchor":{"kind":"text","revision":3,"quote":"abc","start":0,"end":3}}"#.utf8)
        let comment: Knock.Comment = try JSONDecoder().decode(Knock.Comment.self, from: data)
        #expect(comment.isText && comment.captureId == "" && comment.anchor?.revision == 3)
        let again: Knock.Comment = try JSONDecoder().decode(Knock.Comment.self, from: JSONEncoder().encode(comment))
        #expect(again == comment)
    }

    @Test func captureCommentStaysUnchanged() throws {
        let data = Data(#"{"id":"c","capture_id":"cap","n":1,"rect":{"x":0.1,"y":0.2,"w":0.3,"h":0.4},"text":"t"}"#.utf8)
        let comment: Knock.Comment = try JSONDecoder().decode(Knock.Comment.self, from: data)
        #expect(!comment.isText && comment.captureId == "cap" && comment.rect.w == 0.3)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(comment)) as! [String: Any]
        #expect(json["capture_id"] as? String == "cap" && json["rect"] != nil && json["anchor"] == nil)
    }

    @Test func numbersAreSharedAndStayOnTheirRevision() {
        var model = CommentsModel()
        let capture = model.addCapture(revision: 1)
        model.addComment(captureId: capture.id, rect: Rect(x: 0, y: 0, w: 1, h: 1), text: "pin")
        let text = model.addTextComment(anchor: anchor, text: "text")
        model.addTextComment(anchor: TextAnchor(revision: 2, quote: "x", start: 0, end: 1), text: "later")
        #expect(text.n == 2)
        #expect(model.textComments(onRevision: 1).map(\.text) == ["text"])
        #expect(model.textComments(onRevision: 2).map(\.n) == [3])
        model.deleteComment(id: model.comments[0].id)
        #expect(model.orderedComments.map(\.n) == [1, 2])
        #expect(model.orderedComments[0].anchor == anchor)
        model.updateCommentText(id: text.id, text: "edited")
        #expect(model.comments.first { $0.id == text.id }?.anchor == anchor)
    }

    @Test func replyPayloadSendsTextCommentsWithNoCapture() {
        var model = CommentsModel()
        model.addTextComment(anchor: anchor, text: "text")
        let built = ReplyPayloadBuilder.build(model: model, imagesByCaptureId: [:])
        #expect(built.captures.isEmpty)
        #expect(built.comments.map(\.text) == ["text"])
    }

    @Test func storeSavesRestoresAndClearsTextComments() {
        let store = CommentsSessionStore()
        #expect(store.addTextComment(anchor: anchor, text: "  ") == nil)
        let saved = store.addTextComment(anchor: anchor, text: " note ")
        #expect(saved?.text == "note" && saved?.n == 1 && store.nextPinNumber == 2)
        store.clearComments()
        #expect(store.model.comments.isEmpty)
    }
}
