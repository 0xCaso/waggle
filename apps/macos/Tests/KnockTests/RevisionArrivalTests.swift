import Testing
import Foundation
@testable import Knock

// A minimal valid 1x1 PNG, reused from `ReviewViewModelTests`'s fixture.
private let samplePngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

/// Builds a `CaseDetail` fixture with the shapes `RevisionArrival` and
/// `OlderRevisionDisplay` read: a needs_you review case, its revisions, an
/// agent message per revision, and (when `withPriorCapture`) a reply whose
/// capture/comments sit on revision 1 - the "prior" revision once a second
/// one exists.
private func makeDetail(
    revisionCount: Int,
    status: String = "needs_you",
    messages: [(role: String, text: String, createdAt: String)] = [],
    withPriorCapture: Bool = false,
    moreDetailReply: Bool = false,
    decisionReply: Bool = false
) throws -> CaseDetail {
    let revisions = (1...revisionCount).map { n in
        #"{"id":"r_\#(n)","case_id":"c_1","n":\#(n),"created_at":"2026-09-26T10:0\#(n):00Z"}"#
    }.joined(separator: ",")

    let messagesJSON = messages.enumerated().map { index, message in
        #"{"id":"m_\#(index)","case_id":"c_1","role":"\#(message.role)","text":"\#(message.text)","created_at":"\#(message.createdAt)"}"#
    }.joined(separator: ",")

    let repliesJSON: String
    let commentsJSON: String
    if withPriorCapture {
        repliesJSON = #"""
        [{"id":"reply_1","case_id":"c_1","idempotency_key":"idem_1",
          "message":"Go with A. Two fixes.",
          "comments":[{"id":"cm_1","capture_id":"cap_1","n":1,"rect":{"x":0.1,"y":0.1,"w":0.2,"h":0.2},"text":"Default to Monthly."},
                      {"id":"cm_2","capture_id":"cap_1","n":2,"rect":{"x":0.5,"y":0.5,"w":0.2,"h":0.2},"text":"Move the button up."}],
          "captures":[{"id":"cap_1","revision":1,"png_base64":"\#(samplePngBase64)",
                       "annotated_png_base64":"\#(samplePngBase64)","taken_at":"2026-09-26T10:40:00Z"}],
          "state":"delivered","created_at":"2026-09-26T10:44:00Z"}]
        """#
        commentsJSON = #"""
        [{"id":"cm_1","capture_id":"cap_1","n":1,"rect":{"x":0.1,"y":0.1,"w":0.2,"h":0.2},"text":"Default to Monthly."},
         {"id":"cm_2","capture_id":"cap_1","n":2,"rect":{"x":0.5,"y":0.5,"w":0.2,"h":0.2},"text":"Move the button up."}]
        """#
    } else if moreDetailReply {
        repliesJSON = #"""
        [{"id":"reply_1","case_id":"c_1","idempotency_key":"idem_1",
          "message":"Why don't we make the button blue?","intent":"more_detail",
          "comments":[],"captures":[],"state":"queued","created_at":"2026-09-26T10:44:00Z"}]
        """#
        commentsJSON = "[]"
    } else if decisionReply {
        repliesJSON = #"""
        [{"id":"reply_1","case_id":"c_1","idempotency_key":"idem_1",
          "choice":"a","comments":[],"captures":[],"state":"queued","created_at":"2026-09-26T10:44:00Z"}]
        """#
        commentsJSON = "[]"
    } else {
        repliesJSON = "[]"
        commentsJSON = "[]"
    }

    let json = #"""
    {"case":{"id":"c_1","task_id":"t_1","kind":"review","title":"Checkout layout",
      "need":"Confirm v\#(revisionCount) or leave more comments.","why":"Both meet spec.",
      "recommendation":"Ship v\#(revisionCount)","recommendation_why":"Both comments are applied.",
      "options":[], "status":"\#(status)","has_artifact":true,
      "created_at":"2026-09-26T10:00:00Z","updated_at":"2026-09-26T10:41:00Z"},
     "task":{"id":"t_1","name":"Checkout redesign","project":"omea-web"},
     "messages":[\#(messagesJSON)],"revisions":[\#(revisions)],
     "comments":\#(commentsJSON),"replies":\#(repliesJSON)}
    """#
    return try decode(CaseDetail.self, json)
}

/// `CaseDetail.revisionArrival` (docs/design/mvp-values.md §M9): non-nil
/// only for a `needs_you` review case with more than one revision - the only
/// way `knock_update` returns a case there after its first revision.
struct RevisionArrivalTests {
    @Test func isNilWithOnlyOneRevision() throws {
        let detail = try makeDetail(revisionCount: 1)
        #expect(detail.revisionArrival == nil)
    }

    @Test func isNilWhenTheCaseIsNotNeedsYou() throws {
        let detail = try makeDetail(revisionCount: 2, status: "waiting_on_agent")
        #expect(detail.revisionArrival == nil)
    }

    @Test func namesTheLatestAndPriorRevisionNumbers() throws {
        let detail = try makeDetail(revisionCount: 3)
        let arrival = try #require(detail.revisionArrival)
        #expect(arrival.latestRevision == 3)
        #expect(arrival.priorRevision == 2)
    }

    @Test func countsOnlyCommentsOnThePriorRevisionsCaptures() throws {
        let detail = try makeDetail(revisionCount: 2, withPriorCapture: true)
        let arrival = try #require(detail.revisionArrival)
        #expect(arrival.priorRevision == 1)
        #expect(arrival.priorCommentCount == 2)
    }

    @Test func priorCommentCountIsZeroWithNoCapturesOnThatRevision() throws {
        let detail = try makeDetail(revisionCount: 2, withPriorCapture: false)
        let arrival = try #require(detail.revisionArrival)
        #expect(arrival.priorCommentCount == 0)
    }

    @Test func picksTheMostRecentAgentMessageAmongSeveral() throws {
        let detail = try makeDetail(revisionCount: 2, messages: [
            (role: "human", text: "Go with A.", createdAt: "2026-09-26T10:30:00Z"),
            (role: "agent", text: "Working on it.", createdAt: "2026-09-26T10:35:00Z"),
            (role: "agent", text: "Applied both comments in v2.", createdAt: "2026-09-26T10:50:00Z"),
        ])
        let arrival = try #require(detail.revisionArrival)
        #expect(arrival.agentMessage?.text == "Applied both comments in v2.")
    }

    @Test func agentMessageIsNilWithNoAgentMessages() throws {
        let detail = try makeDetail(revisionCount: 2, messages: [
            (role: "human", text: "Go with A.", createdAt: "2026-09-26T10:30:00Z"),
        ])
        let arrival = try #require(detail.revisionArrival)
        #expect(arrival.agentMessage == nil)
    }

    // HAIL-33: a detail request's first knock_update answer has only one
    // revision (the ask may have carried no artifact at all), but the
    // agent's message should still show above the options the same way it
    // does for a returning v2.
    @Test func triggersOnASingleRevisionAfterAMoreDetailReply() throws {
        let detail = try makeDetail(
            revisionCount: 1, messages: [
                (role: "agent", text: "Here's the trade-off write-up.", createdAt: "2026-09-26T10:50:00Z"),
            ], moreDetailReply: true
        )
        let arrival = try #require(detail.revisionArrival)
        #expect(arrival.latestRevision == 1)
        #expect(arrival.priorRevision == 1)
        #expect(arrival.priorCommentCount == 0)
        #expect(arrival.agentMessage?.text == "Here's the trade-off write-up.")
    }

    // A single-revision case with no more_detail history in its replies
    // stays nil - the pre-existing behaviour for an unremarkable first
    // revision (see isNilWithOnlyOneRevision above) must not change for a
    // plain decision reply.
    @Test func staysNilWithOneRevisionAndAPlainDecisionReply() throws {
        let detail = try makeDetail(revisionCount: 1, decisionReply: true)
        #expect(detail.revisionArrival == nil)
    }
}

/// `OlderRevisionDisplay.build` (docs/stories/KNOCK-14.md AC: "with its
/// captures and pins"): pulls a revision's captures out of every reply, each
/// with only its own comments - never another revision's or another
/// capture's.
struct OlderRevisionDisplayTests {
    @Test func includesOnlyCapturesFromTheRequestedRevision() throws {
        let detail = try makeDetail(revisionCount: 2, withPriorCapture: true)
        let display = OlderRevisionDisplay.build(revision: 1, from: detail)
        #expect(display.revision == 1)
        #expect(display.captures.count == 1)
        #expect(display.captures.first?.comments.count == 2)
    }

    @Test func isEmptyForARevisionWithNoStagedCapture() throws {
        let detail = try makeDetail(revisionCount: 2, withPriorCapture: true)
        let display = OlderRevisionDisplay.build(revision: 2, from: detail)
        #expect(display.captures.isEmpty)
    }

    @Test func decodesTheAnnotatedPngIntoAnImage() throws {
        let detail = try makeDetail(revisionCount: 2, withPriorCapture: true)
        let display = OlderRevisionDisplay.build(revision: 1, from: detail)
        let capture = try #require(display.captures.first)
        #expect(try #require(capture.image).size.width > 0)
    }
}

/// `OlderRevisionPlan.plan` (HAIL-142): maps an `artifact.path` result to what the
/// read-only older-revision stage shows.
struct OlderRevisionPlanTests {
    private func result(_ json: String) throws -> ArtifactPathResult { try decode(ArtifactPathResult.self, json) }

    @Test func markdownReadsItsRootFile() throws {
        let r = try result(#"{"kind":"markdown","root":"/s/a.md","entry":""}"#)
        #expect(OlderRevisionPlan.plan(for: r, htmlEnabled: true) == .markdown(path: "/s/a.md"))
    }

    @Test func screenshotAndScreenshotsMapToImages() throws {
        let one = try result(#"{"kind":"screenshot","root":"/s/a.png","entry":""}"#)
        #expect(OlderRevisionPlan.plan(for: one, htmlEnabled: true) == .images(paths: ["/s/a.png"]))
        let many = try result(#"{"kind":"screenshots","root":"","entry":"","items":[{"path":"/s/1.png"},{"path":"/s/2.png","caption":"b"}]}"#)
        #expect(OlderRevisionPlan.plan(for: many, htmlEnabled: true) == .images(paths: ["/s/1.png", "/s/2.png"]))
        let none = try result(#"{"kind":"screenshots","root":"","entry":"","items":[]}"#)
        #expect(OlderRevisionPlan.plan(for: none, htmlEnabled: true) == .unavailable)
    }

    @Test func bundleRendersWhenHtmlIsOn() throws {
        let r = try result(#"{"kind":"html_bundle","root":"/s/b","entry":"/s/b/index.html"}"#)
        #expect(OlderRevisionPlan.plan(for: r, htmlEnabled: true) == .bundle(entry: "/s/b/index.html", root: "/s/b"))
    }

    @Test func bundleWithHtmlOffUsesItsImagePreviewElseANotice() throws {
        let withImage = try result(#"{"kind":"html_bundle","root":"/s/b","entry":"/s/b/index.html","preview":{"kind":"image","path":"/s/b/p.png"}}"#)
        #expect(OlderRevisionPlan.plan(for: withImage, htmlEnabled: false) == .bundleImage(path: "/s/b/p.png"))
        let htmlPreview = try result(#"{"kind":"html_bundle","root":"/s/b","entry":"/s/b/index.html","preview":{"kind":"html","path":"/s/b/p.html"}}"#)
        #expect(OlderRevisionPlan.plan(for: htmlPreview, htmlEnabled: false) == .unavailable)
        let bare = try result(#"{"kind":"html_bundle","root":"/s/b","entry":"/s/b/index.html"}"#)
        #expect(OlderRevisionPlan.plan(for: bare, htmlEnabled: false) == .unavailable)
    }

    @Test func diagramMapsToItsSourceFile() throws {
        let r = try result(#"{"kind":"diagram","root":"/s/d.mmd","entry":""}"#)
        #expect(OlderRevisionPlan.plan(for: r, htmlEnabled: false) == .diagram(path: "/s/d.mmd"))
    }
}
