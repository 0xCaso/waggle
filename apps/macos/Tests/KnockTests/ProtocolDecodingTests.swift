import Testing
import Foundation
@testable import Knock

/// Decodes one sample JSON payload for every Codable type in
/// docs/protocol-mvp.md, per KNOCK-07's acceptance criteria.
struct ProtocolDecodingTests {
    @Test func decodesOptionWithATitle() throws {
        let json = #"{"id":"a","label":"Compact: one screen","title":"Compact"}"#
        #expect(try decode(Option.self, json) == Option(id: "a", label: "Compact: one screen", title: "Compact"))
    }

    @Test func decodesOption() throws {
        let json = #"{"id":"a","label":"Compact"}"#
        let value = try decode(Option.self, json)
        #expect(value == Option(id: "a", label: "Compact"))
    }

    @Test func decodesArtifactScreenshot() throws {
        let json = #"{"type":"screenshot","path":"./shots/a.png"}"#
        let value = try decode(Artifact.self, json)
        #expect(value == .screenshot(path: "./shots/a.png"))
    }

    @Test func decodesArtifactHtmlBundle() throws {
        let json = #"{"type":"html_bundle","dir":"./proto","entry":"index.html"}"#
        let value = try decode(Artifact.self, json)
        #expect(value == .htmlBundle(dir: "./proto", entry: "index.html"))
    }

    @Test func encodesArtifactRoundTrips() throws {
        let value = Artifact.htmlBundle(dir: "./proto", entry: "index.html")
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(Artifact.self, from: data)
        #expect(decoded == value)
    }

    // HAIL-33: markdown, a third artifact kind, staged like a screenshot.
    @Test func decodesArtifactMarkdown() throws {
        let json = #"{"type":"markdown","path":"./notes/explain.md"}"#
        let value = try decode(Artifact.self, json)
        #expect(value == .markdown(path: "./notes/explain.md"))
    }

    @Test func encodesArtifactMarkdownRoundTrips() throws {
        let value = Artifact.markdown(path: "./notes/explain.md")
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(Artifact.self, from: data)
        #expect(decoded == value)
    }

    @Test func decodesArtifactKindMarkdown() throws {
        let value = try decode(ArtifactKind.self, #""markdown""#)
        #expect(value == .markdown)
    }

    // HAIL-40: 2 to 12 images the operator flips through one at a time.
    @Test func decodesArtifactScreenshots() throws {
        let json = #"""
        {"type":"screenshots","items":[{"path":"./shots/1.png","caption":"Home"},{"path":"./shots/2.png"}]}
        """#
        let value = try decode(Artifact.self, json)
        #expect(value == .screenshots(items: [
            ScreenshotItem(path: "./shots/1.png", caption: "Home"),
            ScreenshotItem(path: "./shots/2.png", caption: nil),
        ]))
    }

    @Test func encodesArtifactScreenshotsRoundTrips() throws {
        let value = Artifact.screenshots(items: [
            ScreenshotItem(path: "./shots/1.png", caption: "Home"),
            ScreenshotItem(path: "./shots/2.png", caption: nil),
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(Artifact.self, from: data)
        #expect(decoded == value)
    }

    @Test func decodesArtifactKindScreenshots() throws {
        let value = try decode(ArtifactKind.self, #""screenshots""#)
        #expect(value == .screenshots)
    }

    @Test func decodesRect() throws {
        let json = #"{"x":0.12,"y":0.31,"w":0.76,"h":0.06}"#
        let value = try decode(Rect.self, json)
        #expect(value == Rect(x: 0.12, y: 0.31, w: 0.76, h: 0.06))
    }

    @Test func decodesComment() throws {
        let json = #"""
        {"id":"cm_1","capture_id":"cap_1","n":1,
         "rect":{"x":0.12,"y":0.31,"w":0.76,"h":0.06},
         "text":"Default this to Monthly."}
        """#
        let value = try decode(Knock.Comment.self, json)
        #expect(value.id == "cm_1")
        #expect(value.captureId == "cap_1")
        #expect(value.n == 1)
        #expect(value.text == "Default this to Monthly.")
    }

    @Test func decodesCapture() throws {
        let json = #"""
        {"id":"cap_1","revision":2,"png_base64":"AA==",
         "annotated_png_base64":"BB==","taken_at":"2026-09-26T10:41:00Z",
         "note":"Annual selected"}
        """#
        let value = try decode(Capture.self, json)
        #expect(value.id == "cap_1")
        #expect(value.revision == 2)
        #expect(value.pngBase64 == "AA==")
        #expect(value.annotatedPngBase64 == "BB==")
        #expect(value.note == "Annual selected")
    }

    @Test func decodesCaptureWithoutOptionalNote() throws {
        let json = #"""
        {"id":"cap_1","revision":1,"png_base64":"AA==",
         "annotated_png_base64":"BB==","taken_at":"2026-09-26T10:41:00Z"}
        """#
        let value = try decode(Capture.self, json)
        #expect(value.note == nil)
    }

    @Test func decodesKnockTask() throws {
        let json = #"{"id":"t_1","name":"OME-412","project":"omea-web"}"#
        let value = try decode(KnockTask.self, json)
        #expect(value == KnockTask(id: "t_1", name: "OME-412", project: "omea-web"))
    }

    @Test func decodesRevision() throws {
        let json = #"{"id":"r_1","case_id":"c_1","n":2,"created_at":"2026-09-26T10:41:00Z"}"#
        let value = try decode(Revision.self, json)
        #expect(value.caseId == "c_1")
        #expect(value.n == 2)
    }

    @Test func decodesMessage() throws {
        let json = #"""
        {"id":"m_1","case_id":"c_1","role":"agent",
         "text":"Applied both comments in v3.","created_at":"2026-09-26T10:41:00Z"}
        """#
        let value = try decode(Message.self, json)
        #expect(value.role == .agent)
        #expect(value.text == "Applied both comments in v3.")
    }

    @Test func decodesSession() throws {
        let json = #"""
        {"id":"s_1","cwd":"/Users/x/omea-web","branch":"ome-412-x","pid":123,
         "state":"live","connected_at":"2026-09-26T10:41:00Z"}
        """#
        let value = try decode(Session.self, json)
        #expect(value.state == .live)
        #expect(value.branch == "ome-412-x")
    }

    @Test func decodesSessionWithNullBranch() throws {
        let json = #"""
        {"id":"s_1","cwd":"/Users/x/omea-web","branch":null,"pid":123,
         "state":"ended","connected_at":"2026-09-26T10:41:00Z"}
        """#
        let value = try decode(Session.self, json)
        #expect(value.branch == nil)
        #expect(value.state == .ended)
    }

    // HAIL-46: sessions.list's SessionInfo, the daemon's live-session
    // projection for the Connection screen and `knock doctor`.
    @Test func decodesSessionInfo() throws {
        let json = #"""
        {"id":"s_1","task_id":"t_9","runtime":"codex","task_name":"OME-412","project":"weekend-league",
         "branch":"ome-412-x","cwd":"/Users/me/weekend-league","state":"live","connected_at":"2026-09-26T10:00:00Z",
         "last_seen_at":"2026-09-26T10:41:00Z"}
        """#
        let value = try decode(SessionInfo.self, json)
        #expect(value.runtime == .codex)
        #expect(value.taskId == "t_9")
        #expect(value.cwd == "/Users/me/weekend-league")
        #expect(value.taskName == "OME-412")
        #expect(value.project == "weekend-league")
        #expect(value.branch == "ome-412-x")
        #expect(value.state == .live)
        #expect(value.connectedAt == "2026-09-26T10:00:00Z")
        #expect(value.lastSeenAt == "2026-09-26T10:41:00Z")
    }

    @Test func decodesSessionInfoWithNullBranch() throws {
        let json = #"""
        {"id":"s_1","runtime":"claude","task_name":"knock","project":"knock",
         "branch":null,"state":"ended","connected_at":"2026-09-26T10:00:00Z",
         "last_seen_at":"2026-09-26T10:41:00Z"}
        """#
        let value = try decode(SessionInfo.self, json)
        #expect(value.branch == nil)
        #expect(value.state == .ended)
        // An older daemon sends neither `task_id` nor `cwd`.
        #expect(value.taskId == "")
        #expect(value.cwd == "")
    }

    @Test func decodesCase() throws {
        let json = #"""
        {"id":"c_01J","task_id":"t_1","kind":"review",
         "title":"Checkout layout: compact or detailed?",
         "need":"Pick A or B.","why":"Both meet the spec.",
         "recommendation":"a","recommendation_why":"68% of checkouts...",
         "options":[{"id":"a","label":"Compact"},{"id":"b","label":"Detailed"}],
         "status":"needs_you","has_artifact":true,"runtime":"claude",
         "created_at":"2026-09-26T10:00:00Z","updated_at":"2026-09-26T10:41:00Z"}
        """#
        let value = try decode(Case.self, json)
        #expect(value.kind == .review)
        #expect(value.status == .needsYou)
        #expect(value.hasArtifact == true)
        #expect(value.options.count == 2)
        #expect(value.runtime == .claude)
    }

    /// HAIL-28: the queue row's session label reads these straight off
    /// `Case`, so they must actually decode from the wire's `task_name`/
    /// `project` (daemon/src/protocol/nouns.ts), not just exist as fields.
    @Test func decodesCaseTaskNameAndProject() throws {
        let json = #"""
        {"id":"c_01J","task_id":"t_1","task_name":"Checkout redesign","project":"omea-web","kind":"review",
         "title":"Checkout layout: compact or detailed?",
         "need":"Pick A or B.","why":"Both meet the spec.",
         "recommendation":"a","recommendation_why":"68% of checkouts...",
         "options":[{"id":"a","label":"Compact"},{"id":"b","label":"Detailed"}],
         "status":"needs_you","has_artifact":true,"runtime":"claude",
         "created_at":"2026-09-26T10:00:00Z","updated_at":"2026-09-26T10:41:00Z"}
        """#
        let value = try decode(Case.self, json)
        #expect(value.taskName == "Checkout redesign")
        #expect(value.project == "omea-web")
    }

    /// KNOCK-21 compat: a case from a daemon that predates `task_name`/
    /// `project` (or a fixture that omits them) must still decode, with
    /// both falling back to an empty string rather than throwing.
    @Test func decodesCaseWithoutTaskNameOrProject() throws {
        let json = #"""
        {"id":"c_01J","task_id":"t_1","kind":"review",
         "title":"Checkout layout: compact or detailed?",
         "need":"Pick A or B.","why":"Both meet the spec.",
         "recommendation":"a","recommendation_why":"68% of checkouts...",
         "options":[],"status":"needs_you","has_artifact":true,"runtime":"claude",
         "created_at":"2026-09-26T10:00:00Z","updated_at":"2026-09-26T10:41:00Z"}
        """#
        let value = try decode(Case.self, json)
        #expect(value.taskName == "")
        #expect(value.project == "")
    }

    // HAIL-33: latest_reply_intent, denormalized the same way
    // latest_reply_choice/message are.
    @Test func decodesCaseLatestReplyIntent() throws {
        let json = #"""
        {"id":"c_01J","task_id":"t_1","kind":"question",
         "title":"Pick a layout","need":"N","why":"W",
         "recommendation":"R","recommendation_why":"RW","options":[],
         "status":"waiting_on_agent","has_artifact":false,"runtime":"claude",
         "latest_reply_intent":"more_detail",
         "created_at":"2026-09-26T10:00:00Z","updated_at":"2026-09-26T10:41:00Z"}
        """#
        let value = try decode(Case.self, json)
        #expect(value.latestReplyIntent == .moreDetail)
    }

    @Test func decodesCaseWithoutLatestReplyIntentAsNil() throws {
        let json = #"""
        {"id":"c_01J","task_id":"t_1","kind":"question",
         "title":"Pick a layout","need":"N","why":"W",
         "recommendation":"R","recommendation_why":"RW","options":[],
         "status":"needs_you","has_artifact":false,"runtime":"claude",
         "created_at":"2026-09-26T10:00:00Z","updated_at":"2026-09-26T10:41:00Z"}
        """#
        let value = try decode(Case.self, json)
        #expect(value.latestReplyIntent == nil)
    }

    // HAIL-64: latest_reply_delivered_at, the pickup time.
    @Test func decodesCaseLatestReplyDeliveredAt() throws {
        let json = #"""
        {"id":"c_01J","task_id":"t_1","kind":"question",
         "title":"Pick a layout","need":"N","why":"W",
         "recommendation":"R","recommendation_why":"RW","options":[],
         "status":"waiting_on_agent","has_artifact":false,"runtime":"claude",
         "latest_reply_state":"delivered","latest_reply_delivered_at":"2026-09-26T10:05:00.000Z",
         "created_at":"2026-09-26T10:00:00Z","updated_at":"2026-09-26T10:41:00Z"}
        """#
        let value = try decode(Case.self, json)
        #expect(value.latestReplyDeliveredAt == "2026-09-26T10:05:00.000Z")
        #expect(value.latestReplyDeliveredAtDate == KnockDateFormat.date(from: "2026-09-26T10:05:00Z"))
    }

    @Test func decodesCaseWithoutLatestReplyDeliveredAtAsNil() throws {
        let json = #"""
        {"id":"c_01J","task_id":"t_1","kind":"question",
         "title":"Pick a layout","need":"N","why":"W",
         "recommendation":"R","recommendation_why":"RW","options":[],
         "status":"needs_you","has_artifact":false,"runtime":"claude",
         "created_at":"2026-09-26T10:00:00Z","updated_at":"2026-09-26T10:41:00Z"}
        """#
        #expect(try decode(Case.self, json).latestReplyDeliveredAt == nil)
    }

    // HAIL-33 amendment: follows_case_id, the earlier ask a follow-up
    // points to.
    @Test func decodesCaseFollowsCaseId() throws {
        let json = #"""
        {"id":"c_02K","task_id":"t_1","kind":"question",
         "title":"Show me the numbers","need":"N","why":"W",
         "recommendation":"R","recommendation_why":"RW","options":[],
         "status":"needs_you","has_artifact":false,"runtime":"claude",
         "follows_case_id":"c_01J",
         "created_at":"2026-09-26T10:00:00Z","updated_at":"2026-09-26T10:41:00Z"}
        """#
        let value = try decode(Case.self, json)
        #expect(value.followsCaseId == "c_01J")
    }

    @Test func decodesCaseWithoutFollowsCaseIdAsNil() throws {
        let json = #"""
        {"id":"c_01J","task_id":"t_1","kind":"question",
         "title":"Pick a layout","need":"N","why":"W",
         "recommendation":"R","recommendation_why":"RW","options":[],
         "status":"needs_you","has_artifact":false,"runtime":"claude",
         "created_at":"2026-09-26T10:00:00Z","updated_at":"2026-09-26T10:41:00Z"}
        """#
        let value = try decode(Case.self, json)
        #expect(value.followsCaseId == nil)
    }

    // HAIL-44: replaces_case_id/withdrawn_at, the earlier ask a replacement
    // withdraws.
    @Test func decodesCaseReplacesCaseIdAndWithdrawnAt() throws {
        let json = #"""
        {"id":"c_02K","task_id":"t_1","kind":"question",
         "title":"Speed up the fleet: which fixes should I make?","need":"N","why":"W",
         "recommendation":"R","recommendation_why":"RW","options":[],
         "status":"needs_you","has_artifact":false,"runtime":"claude",
         "replaces_case_id":"c_01J",
         "created_at":"2026-09-26T10:00:00Z","updated_at":"2026-09-26T10:41:00Z"}
        """#
        let value = try decode(Case.self, json)
        #expect(value.replacesCaseId == "c_01J")
        #expect(value.withdrawnAt == nil)
    }

    @Test func decodesCaseWithoutReplacesCaseIdAsNil() throws {
        let json = #"""
        {"id":"c_01J","task_id":"t_1","kind":"question",
         "title":"Pick a layout","need":"N","why":"W",
         "recommendation":"R","recommendation_why":"RW","options":[],
         "status":"needs_you","has_artifact":false,"runtime":"claude",
         "created_at":"2026-09-26T10:00:00Z","updated_at":"2026-09-26T10:41:00Z"}
        """#
        let value = try decode(Case.self, json)
        #expect(value.replacesCaseId == nil)
    }

    @Test func decodesCaseWithdrawnAt() throws {
        let json = #"""
        {"id":"c_01J","task_id":"t_1","kind":"question",
         "title":"Pick a layout","need":"N","why":"W",
         "recommendation":"R","recommendation_why":"RW","options":[],
         "status":"resolved","has_artifact":false,"runtime":"claude",
         "withdrawn_at":"2026-09-28T14:45:00Z",
         "created_at":"2026-09-26T10:00:00Z","updated_at":"2026-09-28T14:45:00Z"}
        """#
        let value = try decode(Case.self, json)
        #expect(value.withdrawnAt == "2026-09-28T14:45:00Z")
    }

    @Test func decodesCaseWithACodexRuntime() throws {
        let json = #"""
        {"id":"c_02K","task_id":"t_1","kind":"question",
         "title":"Pick a layout","need":"N","why":"W",
         "recommendation":"R","recommendation_why":"RW","options":[],
         "status":"needs_you","has_artifact":false,"runtime":"codex",
         "created_at":"2026-09-26T10:00:00Z","updated_at":"2026-09-26T10:41:00Z"}
        """#
        let value = try decode(Case.self, json)
        #expect(value.runtime == .codex)
    }

    @Test func decodesReply() throws {
        let json = #"""
        {"id":"reply_8f2a1c","case_id":"c_01J","idempotency_key":"idem_1",
         "choice":"a","message":"Go with A.","comments":[],"captures":[],
         "state":"delivered","created_at":"2026-09-26T10:44:00Z"}
        """#
        let value = try decode(Reply.self, json)
        #expect(value.state == .delivered)
        #expect(value.choice == "a")
    }

    // HAIL-44: a fourth reply state, for a queued reply superseded by a
    // knock_ask that replaced its case before an agent picked it up.
    @Test func decodesSupersededReply() throws {
        let json = #"""
        {"id":"reply_1","case_id":"c_01J","idempotency_key":"idem_1",
         "choice":"a","comments":[],"captures":[],"state":"superseded",
         "created_at":"2026-09-26T10:44:00Z"}
        """#
        let value = try decode(Reply.self, json)
        #expect(value.state == .superseded)
    }

    @Test func decodesReplyWithoutOptionalFields() throws {
        let json = #"""
        {"id":"reply_1","case_id":"c_01J","idempotency_key":"idem_1",
         "comments":[],"captures":[],"state":"queued",
         "created_at":"2026-09-26T10:44:00Z"}
        """#
        let value = try decode(Reply.self, json)
        #expect(value.choice == nil)
        #expect(value.message == nil)
        #expect(value.intent == .decision, "a daemon that predates intent is read as a plain decision")
    }

    // HAIL-33: reply.submit's intent, "decision" (default) or "more_detail".
    @Test func decodesReplyMoreDetailIntent() throws {
        let json = #"""
        {"id":"reply_2","case_id":"c_01J","idempotency_key":"idem_2",
         "message":"Why don't we make the button blue?","intent":"more_detail",
         "comments":[],"captures":[],"state":"queued","created_at":"2026-09-26T10:44:00Z"}
        """#
        let value = try decode(Reply.self, json)
        #expect(value.intent == .moreDetail)
        #expect(value.choice == nil)
    }

    // HAIL-139: reply.submit's format, "eli5" | "diagram" | "page".
    @Test func decodesReplyMoreDetailFormat() throws {
        let json = #"""
        {"id":"reply_3","case_id":"c_01J","idempotency_key":"idem_3",
         "intent":"more_detail","format":"diagram",
         "comments":[],"captures":[],"state":"queued","created_at":"2026-09-26T10:44:00Z"}
        """#
        let value = try decode(Reply.self, json)
        #expect(value.format == .diagram)
    }

    @Test func decodesReplyWithoutFormatAsNil() throws {
        let json = #"""
        {"id":"reply_4","case_id":"c_01J","idempotency_key":"idem_4",
         "intent":"more_detail",
         "comments":[],"captures":[],"state":"queued","created_at":"2026-09-26T10:44:00Z"}
        """#
        #expect(try decode(Reply.self, json).format == nil)
    }

    // HAIL-139: latest_reply_format, denormalized the same way latest_reply_intent is.
    @Test func decodesCaseLatestReplyFormat() throws {
        let json = #"""
        {"id":"c_01J","task_id":"t_1","kind":"question",
         "title":"Pick a layout","need":"N","why":"W",
         "recommendation":"R","recommendation_why":"RW","options":[],
         "status":"waiting_on_agent","has_artifact":false,"runtime":"claude",
         "latest_reply_intent":"more_detail","latest_reply_format":"page",
         "created_at":"2026-09-26T10:00:00Z","updated_at":"2026-09-26T10:41:00Z"}
        """#
        let value = try decode(Case.self, json)
        #expect(value.latestReplyIntent == .moreDetail)
        #expect(value.latestReplyFormat == .page)
    }

    @Test func decodesCaseWithoutLatestReplyFormatAsNil() throws {
        let json = #"""
        {"id":"c_01J","task_id":"t_1","kind":"question",
         "title":"Pick a layout","need":"N","why":"W",
         "recommendation":"R","recommendation_why":"RW","options":[],
         "status":"needs_you","has_artifact":false,"runtime":"claude",
         "created_at":"2026-09-26T10:00:00Z","updated_at":"2026-09-26T10:41:00Z"}
        """#
        #expect(try decode(Case.self, json).latestReplyFormat == nil)
    }

    @Test func encodesReplySubmitParamsWithIntent() throws {
        let params = ReplySubmitParams(
            caseId: "c_01J", idempotencyKey: "idem_1", choice: nil,
            message: "Show me a prototype", comments: [], captures: [], intent: .moreDetail
        )
        let data = try JSONEncoder().encode(params)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""intent":"more_detail""#))
    }

    @Test func decodesCaseDetail() throws {
        let json = #"""
        {"case":{"id":"c_01J","task_id":"t_1","kind":"review",
                  "title":"Checkout layout: compact or detailed?",
                  "need":"Pick A or B.","why":"Both meet the spec.",
                  "recommendation":"a","recommendation_why":"68%...",
                  "options":[],"status":"needs_you","has_artifact":true,"runtime":"claude",
                  "created_at":"2026-09-26T10:00:00Z","updated_at":"2026-09-26T10:41:00Z"},
         "task":{"id":"t_1","name":"Checkout redesign","project":"omea-web"},
         "messages":[],"revisions":[],"comments":[],"replies":[]}
        """#
        let value = try decode(CaseDetail.self, json)
        #expect(value.case.id == "c_01J")
        #expect(value.task.project == "omea-web")
    }

    @Test func decodesArtifactPathResult() throws {
        let json = #"{"kind":"html_bundle","root":"/data/bundles/c_1/r2","entry":"index.html"}"#
        let value = try decode(ArtifactPathResult.self, json)
        #expect(value.kind == .htmlBundle)
        #expect(value.items == nil, "every other kind carries no items")
    }

    /// HAIL-40: a `screenshots` revision has no single `root`/`entry` - its
    /// ordered, absolute blob paths and captions come back in `items`
    /// instead (daemon/src/store.ts `artifactPath`).
    @Test func decodesArtifactPathResultScreenshotsItems() throws {
        let json = #"""
        {"kind":"screenshots","root":"","entry":"",
         "items":[{"path":"/data/blobs/aa.png","caption":"Home"},{"path":"/data/blobs/bb.png"}]}
        """#
        let value = try decode(ArtifactPathResult.self, json)
        #expect(value.kind == .screenshots)
        #expect(value.root == "")
        #expect(value.entry == "")
        #expect(value.items == [
            ScreenshotItem(path: "/data/blobs/aa.png", caption: "Home"),
            ScreenshotItem(path: "/data/blobs/bb.png", caption: nil),
        ])
    }

    @Test func encodesArtifactPathResultScreenshotsItemsRoundTrips() throws {
        let value = ArtifactPathResult(
            kind: .screenshots, root: "", entry: "",
            items: [ScreenshotItem(path: "/data/blobs/aa.png", caption: "Home")],
            viewport: nil, preview: nil
        )
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ArtifactPathResult.self, from: data)
        #expect(decoded == value)
    }

    // HAIL-49: an html_bundle revision may declare a viewport and/or a
    // preview - both absent from the JSON decode as nil, the same way
    // `items` already does for every non-screenshots kind.
    @Test func decodesArtifactPathResultWithNeitherViewportNorPreview() throws {
        let json = #"{"kind":"html_bundle","root":"/data/bundles/c_1/r2","entry":"index.html"}"#
        let value = try decode(ArtifactPathResult.self, json)
        #expect(value.viewport == nil)
        #expect(value.preview == nil)
    }

    @Test func decodesArtifactPathResultViewport() throws {
        let json = #"""
        {"kind":"html_bundle","root":"/data/bundles/c_1/r2","entry":"index.html",
         "viewport":{"width":390,"height":844}}
        """#
        let value = try decode(ArtifactPathResult.self, json)
        #expect(value.viewport == ViewportSize(width: 390, height: 844))
    }

    @Test func decodesArtifactPathResultPreview() throws {
        let json = #"""
        {"kind":"html_bundle","root":"/data/bundles/c_1/r2","entry":"index.html",
         "preview":{"kind":"html","path":"/data/bundles/c_1/r2/preview.html"}}
        """#
        let value = try decode(ArtifactPathResult.self, json)
        #expect(value.preview == ArtifactPreviewInfo(kind: .html, path: "/data/bundles/c_1/r2/preview.html"))
    }

    @Test func decodesServiceStatus() throws {
        let json = #"""
        {"version":"0.1.0","data_root":"/Users/x/Library/Application Support/Knock",
         "sessions_live":2,"cases_open":3,
         "exec_path":"/Users/x/Applications/Waggle.app/Contents/Resources/knock"}
        """#
        let value = try decode(ServiceStatus.self, json)
        #expect(value.sessionsLive == 2)
        #expect(value.casesOpen == 3)
        #expect(value.execPath == "/Users/x/Applications/Waggle.app/Contents/Resources/knock")
    }

    @Test func decodesServiceStatusWithoutExecPathAsNil() throws {
        // An older daemon predates exec_path; the app must still decode its
        // status and treat the missing path as "not my daemon" (HAIL-27).
        let json = #"{"version":"0.1.0","data_root":"/x","sessions_live":0,"cases_open":0}"#
        let value = try decode(ServiceStatus.self, json)
        #expect(value.execPath == nil)
    }

    @Test func decodesEvent() throws {
        let json = #"{"type":"case.created","case_id":"c_01J","at":"2026-09-26T10:41:00Z"}"#
        let value = try decode(Event.self, json)
        #expect(value.type == .caseCreated)
        #expect(value.caseId == "c_01J")
        #expect(value.replyId == nil)
        #expect(value.sessionId == nil)
    }

    @Test func decodesAllEventTypes() throws {
        for raw in ["case.created", "case.updated", "revision.added", "reply.state_changed", "session.state_changed"] {
            let json = #"{"type":"\#(raw)","at":"2026-09-26T10:41:00Z"}"#
            let value = try decode(Event.self, json)
            #expect(value.type.rawValue == raw)
        }
    }

    @Test func decodesAllCaseStatuses() throws {
        for raw in ["needs_you", "waiting_on_agent", "resolved"] {
            #expect(CaseStatus(rawValue: raw) != nil)
        }
    }

    @Test func decodesAllReplyStatuses() throws {
        for raw in ["queued", "delivered", "failed"] {
            #expect(ReplyStatus(rawValue: raw) != nil)
        }
    }

    @Test func decodesAllSessionStates() throws {
        for raw in ["live", "disconnected", "ended"] {
            #expect(SessionState(rawValue: raw) != nil)
        }
    }
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}
