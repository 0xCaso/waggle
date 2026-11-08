import Testing
import Foundation
import AppKit
@testable import Knock

/// `artifact.path` result shapes match daemon/src/store.ts `artifactPath`:
/// a screenshot's `root` is the absolute image file, `entry` empty; an
/// `html_bundle`'s `root` is the revision directory, `entry` the absolute
/// entry file path.
private func artifactPathResultJSON(kind: String, root: String, entry: String) -> String {
    #"{"kind":"\#(kind)","root":"\#(root)","entry":"\#(entry)"}"#
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

/// HAIL-40: `artifactPath`'s items JSON for a `screenshots` revision -
/// `root`/`entry` are empty, the ordered blob paths/captions live in `items`.
private func artifactPathScreenshotsResultJSON(items: [(path: String, caption: String?)]) -> String {
    let itemsJSON = items.map { item -> String in
        if let caption = item.caption {
            return #"{"path":"\#(item.path)","caption":"\#(caption)"}"#
        }
        return #"{"path":"\#(item.path)"}"#
    }.joined(separator: ",")
    return #"{"kind":"screenshots","root":"","entry":"","items":[\#(itemsJSON)]}"#
}

private func sampleCaseDetailJSON(revisionCount: Int) -> String {
    let revisions = (1...revisionCount).map { n in
        #"{"id":"r_\#(n)","case_id":"c_1","n":\#(n),"created_at":"2026-09-26T10:00:00Z"}"#
    }.joined(separator: ",")
    return #"""
    {"case":{"id":"c_1","task_id":"t_1","kind":"review","title":"Checkout layout",
      "need":"Pick A or B.","why":"Both meet spec.","recommendation":"a",
      "recommendation_why":"68%...","options":[{"id":"a","label":"Compact"}],
      "status":"needs_you","has_artifact":true,"runtime":"claude","created_at":"2026-09-26T10:00:00Z",
      "updated_at":"2026-09-26T10:41:00Z"},
     "task":{"id":"t_1","name":"Checkout redesign","project":"omea-web"},
     "messages":[],"revisions":[\#(revisions)],"comments":[],"replies":[]}
    """#
}

/// A returned-revision (docs/design/mvp-values.md §M9) fixture: two
/// revisions, an agent message, and revision 1's own capture/comments -
/// enough for both `revisionArrival` and `viewOlderRevision()`.
private func sampleCaseDetailJSONWithRevisionArrival() -> String {
    #"""
    {"case":{"id":"c_1","task_id":"t_1","kind":"review","title":"Checkout layout",
      "need":"Confirm v2 or leave more comments.","why":"Both meet spec.",
      "recommendation":"Ship v2","recommendation_why":"Both comments are applied.",
      "options":[],"status":"needs_you","has_artifact":true,
      "created_at":"2026-09-26T10:00:00Z","updated_at":"2026-09-26T10:41:00Z"},
     "task":{"id":"t_1","name":"Checkout redesign","project":"omea-web"},
     "messages":[{"id":"m_1","case_id":"c_1","role":"agent",
       "text":"Applied both comments in v2.","created_at":"2026-09-26T10:50:00Z"}],
     "revisions":[{"id":"r_1","case_id":"c_1","n":1,"created_at":"2026-09-26T10:00:00Z"},
                   {"id":"r_2","case_id":"c_1","n":2,"created_at":"2026-09-26T10:45:00Z"}],
     "comments":[{"id":"cm_1","capture_id":"cap_1","n":1,"rect":{"x":0.1,"y":0.1,"w":0.2,"h":0.2},"text":"Default to Monthly."}],
     "replies":[{"id":"reply_1","case_id":"c_1","idempotency_key":"idem_1","message":"Go with A.",
       "comments":[{"id":"cm_1","capture_id":"cap_1","n":1,"rect":{"x":0.1,"y":0.1,"w":0.2,"h":0.2},"text":"Default to Monthly."}],
       "captures":[{"id":"cap_1","revision":1,
         "png_base64":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
         "annotated_png_base64":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
         "taken_at":"2026-09-26T10:40:00Z"}],
       "state":"delivered","created_at":"2026-09-26T10:44:00Z"}]}
    """#
}

@MainActor
struct ReviewViewModelTests {
    @Test func loadsAScreenshotArtifactFitToItsLatestRevision() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)

        let imagePath = try Self.writeSampleScreenshot()

        server.onRequest = { method, id, _ in
            guard let id else { return nil }
            switch method {
            case "artifact.path":
                return jsonRPCOK(id: id, result: artifactPathResultJSON(kind: "screenshot", root: imagePath, entry: ""))
            default:
                return nil
            }
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let detail = try decode(CaseDetail.self, sampleCaseDetailJSON(revisionCount: 2))
        let viewModel = ReviewViewModel(client: client)
        await viewModel.load(detail: detail)

        guard case .screenshot(_, let revision) = viewModel.artifactState else {
            Issue.record("expected .screenshot, got \(viewModel.artifactState)")
            return
        }
        #expect(revision == 2, "should load the latest revision, not the first")
        #expect(viewModel.mode == .comment, "Interact has nothing to offer a screenshot")
        #expect(viewModel.tab == .question, "the tab defaults to Question even for a case that opens straight into Comment mode")

        let capture = viewModel.commentsStore.currentCapture
        #expect(capture?.n == 1, "a screenshot case has no Interact to switch from, so its first capture is automatic")
        #expect(capture?.revision == 2)
        #expect(viewModel.commentsStore.currentImage != nil)
    }

    /// HAIL-40: every image loads as its own capture, in order, up front -
    /// no Interact to switch from, so Comment mode starts immediately with
    /// screen 1 shown, matching the single-screenshot case's automatic entry.
    @Test func loadsAScreenshotsArtifactAsCapturesUpFrontOnScreenOne() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let first = try Self.writeSampleScreenshot()
        let second = try Self.writeSampleScreenshot()
        let third = try Self.writeSampleScreenshot()

        server.onRequest = { method, id, _ in
            guard let id, method == "artifact.path" else { return nil }
            return jsonRPCOK(id: id, result: artifactPathScreenshotsResultJSON(items: [
                (path: first, caption: "Home"),
                (path: second, caption: nil),
                (path: third, caption: "Checkout"),
            ]))
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let detail = try decode(CaseDetail.self, sampleCaseDetailJSON(revisionCount: 1))
        let viewModel = ReviewViewModel(client: client)
        await viewModel.load(detail: detail)

        guard case .screenshots(let revision) = viewModel.artifactState else {
            Issue.record("expected .screenshots, got \(viewModel.artifactState)")
            return
        }
        #expect(revision == 1)
        #expect(viewModel.mode == .comment)
        #expect(viewModel.tab == .question, "the tab defaults to Question even for a screenshots case")
        #expect(viewModel.commentsStore.model.captures.map(\.n) == [1, 2, 3], "every image is its own capture, added up front")
        #expect(viewModel.commentsStore.currentCapture?.n == 1, "opens on screen 1")
    }

    /// `ReviewViewModel.stepScreen`/`selectScreen` (HAIL-40): the thumbnail
    /// strip and ← / → navigation, clamped at both ends.
    @Test func stepScreenMovesForwardAndBackClampedAtTheEnds() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let first = try Self.writeSampleScreenshot()
        let second = try Self.writeSampleScreenshot()
        let third = try Self.writeSampleScreenshot()

        server.onRequest = { method, id, _ in
            guard let id, method == "artifact.path" else { return nil }
            return jsonRPCOK(id: id, result: artifactPathScreenshotsResultJSON(items: [
                (path: first, caption: nil), (path: second, caption: nil), (path: third, caption: nil),
            ]))
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let detail = try decode(CaseDetail.self, sampleCaseDetailJSON(revisionCount: 1))
        let viewModel = ReviewViewModel(client: client)
        await viewModel.load(detail: detail)

        let captures = viewModel.commentsStore.model.captures
        #expect(viewModel.commentsStore.currentCapture?.n == 1)

        viewModel.stepScreen(by: 1)
        #expect(viewModel.commentsStore.currentCapture?.n == 2)

        viewModel.stepScreen(by: 1)
        #expect(viewModel.commentsStore.currentCapture?.n == 3)

        viewModel.stepScreen(by: 1)
        #expect(viewModel.commentsStore.currentCapture?.n == 3, "clamped at the last screen")

        viewModel.stepScreen(by: -1)
        #expect(viewModel.commentsStore.currentCapture?.n == 2)

        viewModel.selectScreen(id: captures[0].id)
        #expect(viewModel.commentsStore.currentCapture?.n == 1, "the thumbnail strip's click handler selects by id")

        viewModel.stepScreen(by: -1)
        #expect(viewModel.commentsStore.currentCapture?.n == 1, "clamped at the first screen")
    }

    @Test func loadsAnHtmlBundleArtifactInInteractModeWhenIsolationIsAvailable() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)

        let bundleDir = try Self.writeSampleBundle()
        let entryPath = bundleDir.appendingPathComponent("index.html").path

        server.onRequest = { method, id, _ in
            guard let id else { return nil }
            switch method {
            case "artifact.path":
                return jsonRPCOK(id: id, result: artifactPathResultJSON(kind: "html_bundle", root: bundleDir.path, entry: entryPath))
            default:
                return nil
            }
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let detail = try decode(CaseDetail.self, sampleCaseDetailJSON(revisionCount: 1))
        let viewModel = ReviewViewModel(client: client)
        await viewModel.load(detail: detail)

        guard case .htmlBundle(let entryURL, let directoryURL, let revision, _) = viewModel.artifactState else {
            Issue.record("expected .htmlBundle, got \(viewModel.artifactState)")
            return
        }
        #expect(entryURL.path == entryPath)
        #expect(directoryURL.path == bundleDir.path)
        #expect(revision == 1)
        #expect(viewModel.mode == .interact)
    }

    /// HAIL-127: the prototype's zoom starts at 100% for every ask, and a new
    /// revision shown in place (HAIL-114) resets it too.
    @Test func prototypeZoomResetsOnLoadAndOnANewRevision() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let bundleDir = try Self.writeSampleBundle()
        let entryPath = bundleDir.appendingPathComponent("index.html").path
        server.onRequest = { method, id, _ in
            guard let id, method == "artifact.path" else { return nil }
            return jsonRPCOK(id: id, result: artifactPathResultJSON(kind: "html_bundle", root: bundleDir.path, entry: entryPath))
        }
        try server.start()
        defer { server.stop() }
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let viewModel = ReviewViewModel(client: client)
        viewModel.prototypeZoom.setScale(3)
        await viewModel.load(detail: try decode(CaseDetail.self, sampleCaseDetailJSON(revisionCount: 1)))
        #expect(viewModel.prototypeZoom.storedScale == 1, "a new ask opens at 100%")

        viewModel.prototypeZoom.setScale(2)
        await viewModel.refresh(detail: try decode(CaseDetail.self, sampleCaseDetailJSON(revisionCount: 2)))
        #expect(viewModel.artifactState.revision == 2)
        #expect(viewModel.prototypeZoom.storedScale == 1, "a new revision opens at 100%")
    }

    /// `KNOCK_REVIEW_MODE=comment` (Amendments): the orchestrator's evidence
    /// hook, since it cannot send the "C" keystroke to open Comment mode
    /// itself. No webview is registered in this headless test, so the
    /// capture step itself yields nothing to snapshot; this only proves the
    /// env var forces the mode switch on load.
    @Test func knockReviewModeEnvVarStartsAnHtmlBundleCaseInCommentMode() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)

        let bundleDir = try Self.writeSampleBundle()
        let entryPath = bundleDir.appendingPathComponent("index.html").path

        server.onRequest = { method, id, _ in
            guard let id else { return nil }
            switch method {
            case "artifact.path":
                return jsonRPCOK(id: id, result: artifactPathResultJSON(kind: "html_bundle", root: bundleDir.path, entry: entryPath))
            default:
                return nil
            }
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let detail = try decode(CaseDetail.self, sampleCaseDetailJSON(revisionCount: 1))
        let viewModel = ReviewViewModel(client: client, environment: ["KNOCK_REVIEW_MODE": "comment"])
        await viewModel.load(detail: detail)

        #expect(viewModel.mode == .comment)
    }

    /// docs/design/mvp-values.md §M9: `load` reads `revisionArrival` off the
    /// detail it is given, once, at load time.
    @Test func loadSetsRevisionArrivalForAReturnedRevision() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let imagePath = try Self.writeSampleScreenshot()
        server.onRequest = { method, id, _ in
            guard let id, method == "artifact.path" else { return nil }
            return jsonRPCOK(id: id, result: artifactPathResultJSON(kind: "screenshot", root: imagePath, entry: ""))
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let detail = try decode(CaseDetail.self, sampleCaseDetailJSONWithRevisionArrival())
        let viewModel = ReviewViewModel(client: client)
        await viewModel.load(detail: detail)

        let arrival = try #require(viewModel.revisionArrival)
        #expect(arrival.latestRevision == 2)
        #expect(arrival.priorRevision == 1)
        #expect(arrival.priorCommentCount == 1)
        #expect(arrival.agentMessage?.text == "Applied both comments in v2.")
    }

    /// docs/stories/KNOCK-14.md AC: the "view v<n-1>" link freezes the viewer
    /// on the prior revision's own captures and pins, read-only, until the
    /// friend returns to the live latest one.
    @Test func viewOlderRevisionAndReturnToLatestRevisionToggleTheReadOnlyDisplay() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let imagePath = try Self.writeSampleScreenshot()
        server.onRequest = { method, id, _ in
            guard let id, method == "artifact.path" else { return nil }
            return jsonRPCOK(id: id, result: artifactPathResultJSON(kind: "screenshot", root: imagePath, entry: ""))
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let detail = try decode(CaseDetail.self, sampleCaseDetailJSONWithRevisionArrival())
        let viewModel = ReviewViewModel(client: client)
        await viewModel.load(detail: detail)

        #expect(viewModel.olderRevisionDisplay == nil)
        viewModel.viewOlderRevision()
        let older = try #require(viewModel.olderRevisionDisplay)
        #expect(older.revision == 1)
        #expect(older.captures.count == 1)
        #expect(older.captures.first?.comments.count == 1)

        viewModel.returnToLatestRevision()
        #expect(viewModel.olderRevisionDisplay == nil)
    }

    /// HAIL-142: a revision with no comments still shows its own artifact.
    @Test func viewOlderRevisionLoadsThatRevisionsMarkdown() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let mdPath = NSTemporaryDirectory() + "older-\(UUID().uuidString).md"
        try "# Revision one".write(toFile: mdPath, atomically: true, encoding: .utf8)
        server.onRequest = { method, id, _ in
            guard let id, method == "artifact.path" else { return nil }
            return jsonRPCOK(id: id, result: artifactPathResultJSON(kind: "markdown", root: mdPath, entry: ""))
        }
        try server.start()
        defer { server.stop() }
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let detail = try decode(CaseDetail.self, sampleCaseDetailJSONWithRevisionArrival())
        let viewModel = ReviewViewModel(client: client)
        await viewModel.load(detail: detail)
        viewModel.viewOlderRevision()
        _ = try await pollUntil(.seconds(20)) {
            if case .loading? = viewModel.olderRevisionDisplay?.content { return false } else { return true }
        }
        guard case .markdown(let text)? = viewModel.olderRevisionDisplay?.content else {
            Issue.record("expected markdown content")
            return
        }
        #expect(text == "# Revision one")
    }

    /// Entering Interact/Comment while browsing an earlier revision would
    /// freeze a *new* capture onto the wrong revision - both must be a no-op
    /// until the friend returns to the latest one.
    @Test func enteringInteractOrCommentModeIsANoOpWhileBrowsingAnOlderRevision() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let bundleDir = try Self.writeSampleBundle()
        let entryPath = bundleDir.appendingPathComponent("index.html").path
        server.onRequest = { method, id, _ in
            guard let id, method == "artifact.path" else { return nil }
            return jsonRPCOK(id: id, result: artifactPathResultJSON(kind: "html_bundle", root: bundleDir.path, entry: entryPath))
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let detail = try decode(CaseDetail.self, sampleCaseDetailJSONWithRevisionArrival())
        let viewModel = ReviewViewModel(client: client)
        await viewModel.load(detail: detail)
        #expect(viewModel.mode == .interact)

        viewModel.viewOlderRevision()
        viewModel.enterInteractMode()
        #expect(viewModel.mode == .interact, "no live mode to switch to while browsing read-only")
        await viewModel.enterCommentMode()
        #expect(viewModel.mode == .interact, "entering Comment mode must not fire while browsing read-only")
        #expect(viewModel.commentsStore.model.captures.isEmpty, "no new capture was taken")
    }

    /// HAIL-35 contract: "Re-entering Comment mode when nothing changed on
    /// the page ... reuses the last capture instead of making a new one.
    /// After interaction, a new capture is still taken." Pure and
    /// independent of any live webview.
    @Test func showExistingCommentsSelectsTheLatestCaptureWithoutFreezingANewOne() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let bundleDir = try Self.writeSampleBundle()
        let entryPath = bundleDir.appendingPathComponent("index.html").path
        server.onRequest = { method, id, _ in
            guard let id, method == "artifact.path" else { return nil }
            return jsonRPCOK(id: id, result: artifactPathResultJSON(kind: "html_bundle", root: bundleDir.path, entry: entryPath))
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let detail = try decode(CaseDetail.self, sampleCaseDetailJSON(revisionCount: 1))
        let viewModel = ReviewViewModel(client: client)
        await viewModel.load(detail: detail)
        #expect(viewModel.mode == .interact)

        // No webview registered in this headless test, so seed a capture
        // directly - `showExistingComments()` must not attempt to freeze
        // another one regardless.
        viewModel.commentsStore.addCapture(image: NSImage(), revision: 1)
        #expect(viewModel.commentsStore.model.captures.count == 1)

        viewModel.showExistingComments()

        #expect(viewModel.mode == .comment)
        #expect(viewModel.tab == .comments, "\"Show\" opens the Comments tab")
        #expect(viewModel.commentsStore.model.captures.count == 1, "\"Show\" looks at the existing capture, it does not take a new one")
    }

    /// HAIL-75: saving a comment in Comment mode leaves the right column where
    /// the operator put it (Question by default).
    @Test func creatingACommentLeavesTheSelectedTabUnchanged() async throws {
        let viewModel = try await Self.loadedHtmlViewModel()
        await viewModel.enterCommentMode()
        #expect(viewModel.tab == .question)

        viewModel.beginLiveDraft(rect: Rect(x: 0.1, y: 0.1, w: 0.2, h: 0.2))
        viewModel.commentsStore.updateDraftText("Make this bigger")
        // No web view in a unit test, so the snapshot fails and nothing is
        // saved; the tab must not move either way.
        await viewModel.commitLiveDraft()
        #expect(viewModel.mode == .comment)
        #expect(viewModel.tab == .question, "Question stays selected while commenting")

        viewModel.selectTab(.comments)
        viewModel.beginLiveDraft(rect: Rect(x: 0.5, y: 0.5, w: 0.2, h: 0.2))
        #expect(viewModel.tab == .comments, "a tab the operator chose is not changed either")
    }

    @Test func showExistingCommentsIsANoOpWithoutAnyCaptureYet() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let bundleDir = try Self.writeSampleBundle()
        let entryPath = bundleDir.appendingPathComponent("index.html").path
        server.onRequest = { method, id, _ in
            guard let id, method == "artifact.path" else { return nil }
            return jsonRPCOK(id: id, result: artifactPathResultJSON(kind: "html_bundle", root: bundleDir.path, entry: entryPath))
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let detail = try decode(CaseDetail.self, sampleCaseDetailJSON(revisionCount: 1))
        let viewModel = ReviewViewModel(client: client)
        await viewModel.load(detail: detail)

        viewModel.showExistingComments()

        #expect(viewModel.mode == .interact, "nothing to show yet, so \"Show\" does nothing")
        #expect(viewModel.tab == .question, "the no-op must not touch the tab either")
    }

    /// HAIL-56 contract: "The tab no longer changes when the tool changes" -
    /// pressing C (I → Comment) alone must never move `tab` off Question.
    @Test func enteringCommentModeAloneDoesNotChangeTheTab() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let bundleDir = try Self.writeSampleBundle()
        let entryPath = bundleDir.appendingPathComponent("index.html").path
        server.onRequest = { method, id, _ in
            guard let id, method == "artifact.path" else { return nil }
            return jsonRPCOK(id: id, result: artifactPathResultJSON(kind: "html_bundle", root: bundleDir.path, entry: entryPath))
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let detail = try decode(CaseDetail.self, sampleCaseDetailJSON(revisionCount: 1))
        let viewModel = ReviewViewModel(client: client)
        await viewModel.load(detail: detail)
        #expect(viewModel.tab == .question)

        await viewModel.enterCommentMode(force: true)
        #expect(viewModel.mode == .comment)
        #expect(viewModel.tab == .question, "a tool switch alone never moves the tab")

        viewModel.enterInteractMode()
        #expect(viewModel.mode == .interact)
        #expect(viewModel.tab == .question)
    }

    /// HAIL-56 contract: "placing a new pin switches to Comments so the note
    /// being written is visible" - and the direct pick (`selectTab`) always
    /// wins regardless of the current tool.
    @Test func selectTabAndNoteDraftBeganSwitchTheRightColumn() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let imagePath = try Self.writeSampleScreenshot()
        server.onRequest = { method, id, _ in
            guard let id, method == "artifact.path" else { return nil }
            return jsonRPCOK(id: id, result: artifactPathResultJSON(kind: "screenshot", root: imagePath, entry: ""))
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let detail = try decode(CaseDetail.self, sampleCaseDetailJSON(revisionCount: 1))
        let viewModel = ReviewViewModel(client: client)
        await viewModel.load(detail: detail)
        #expect(viewModel.tab == .question)

        viewModel.selectTab(.comments)
        #expect(viewModel.tab == .comments)

        viewModel.selectTab(.question)
        #expect(viewModel.tab == .question)
    }

    /// `ReviewViewModel.shouldReuseLastCapture`: the pure "did anything
    /// change since the last capture" rule (HAIL-35 contract test list:
    /// "the 'reuse last capture when nothing changed' rule").
    @Test func reusesTheLastCaptureOnTheSameRevisionWithoutInteraction() {
        let reuse = ReviewViewModel.shouldReuseLastCapture(
            lastCapture: Self.sampleCapture(revision: 2), currentRevision: 2, hasInteractedSinceLastCapture: false
        )
        #expect(reuse)
    }

    @Test func takesANewCaptureAfterInteractionEvenOnTheSameRevision() {
        let reuse = ReviewViewModel.shouldReuseLastCapture(
            lastCapture: Self.sampleCapture(revision: 2), currentRevision: 2, hasInteractedSinceLastCapture: true
        )
        #expect(reuse == false, "\"a new C makes a new capture\" once something happened")
    }

    @Test func takesANewCaptureWhenTheRevisionChangedEvenWithoutInteraction() {
        let reuse = ReviewViewModel.shouldReuseLastCapture(
            lastCapture: Self.sampleCapture(revision: 1), currentRevision: 2, hasInteractedSinceLastCapture: false
        )
        #expect(reuse == false, "a new revision must always freeze its own capture, never reuse an older revision's")
    }

    /// HAIL-65: switching tools never snapshots or creates a capture, and the
    /// mode flips without any capture work.
    @Test func switchingBetweenInteractAndCommentCreatesNoCapture() async throws {
        let viewModel = try await Self.loadedHtmlViewModel()
        #expect(viewModel.mode == .interact)

        for _ in 0..<3 {
            await viewModel.enterCommentMode()
            #expect(viewModel.mode == .comment)
            viewModel.enterInteractMode()
            #expect(viewModel.mode == .interact)
        }

        #expect(viewModel.commentsStore.model.captures.isEmpty, "empty captures are never created by a tool switch")
        #expect(viewModel.commentsStore.commentedCaptures.isEmpty)
    }

    @Test func aLiveDraftCreatesNoCaptureUntilSavedAndCancelsOnInteract() async throws {
        let viewModel = try await Self.loadedHtmlViewModel()
        await viewModel.enterCommentMode()

        viewModel.beginLiveDraft(rect: Rect(x: 0.1, y: 0.1, w: 0.2, h: 0.2))
        #expect(viewModel.commentsStore.draftPin != nil)
        #expect(viewModel.commentsStore.model.captures.isEmpty)
        #expect(viewModel.tab == .question, "placing a pin leaves the tab alone (HAIL-75: comments are edited inline)")

        viewModel.enterInteractMode()
        #expect(viewModel.commentsStore.draftPin == nil)
        #expect(viewModel.commentsStore.pending == nil)
        #expect(viewModel.commentsStore.model.captures.isEmpty)
    }

    @Test func theLatestCaptureIsLiveUntilThePageIsTouched() async throws {
        let viewModel = try await Self.loadedHtmlViewModel()
        #expect(viewModel.liveCapture == nil, "no capture yet")

        let record = viewModel.commentsStore.addCapture(image: NSImage(), revision: 1)
        #expect(viewModel.liveCapture?.id == record.id)
        #expect(!viewModel.showsStillOverLive)

        viewModel.webViewCapture.recordInteraction()
        #expect(viewModel.liveCapture == nil, "the page changed, so a new comment needs a new capture")
        viewModel.commentsStore.selectCapture(id: record.id)
        #expect(viewModel.showsStillOverLive, "an older capture shows as a still only in that case")

        viewModel.commentsStore.clearSelection()
        #expect(!viewModel.showsStillOverLive)
    }

    @Test func enteringCommentModeClearsAPickedStill() async throws {
        let viewModel = try await Self.loadedHtmlViewModel()
        let record = viewModel.commentsStore.addCapture(image: NSImage(), revision: 1)
        viewModel.webViewCapture.recordInteraction()
        viewModel.commentsStore.selectCapture(id: record.id)
        #expect(viewModel.commentsStore.selectedCaptureId == record.id)

        viewModel.enterInteractMode()
        await viewModel.enterCommentMode()

        #expect(viewModel.commentsStore.selectedCaptureId == nil, "back on the live page")
    }

    private static func loadedHtmlViewModel() async throws -> ReviewViewModel {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let bundleDir = try writeSampleBundle()
        let entryPath = bundleDir.appendingPathComponent("index.html").path
        server.onRequest = { method, id, _ in
            guard let id, method == "artifact.path" else { return nil }
            return jsonRPCOK(id: id, result: artifactPathResultJSON(kind: "html_bundle", root: bundleDir.path, entry: entryPath))
        }
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        let detail = try decode(CaseDetail.self, sampleCaseDetailJSON(revisionCount: 1))
        let viewModel = ReviewViewModel(client: client)
        await viewModel.load(detail: detail)
        return viewModel
    }

    private static func sampleCapture(revision: Int) -> CaptureRecord {
        CaptureRecord(id: "cap_1", revision: revision, n: 1, takenAt: Date(), scrollFraction: 0)
    }

    private static func writeSampleScreenshot() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("shot.png").path
        // A minimal valid 1x1 PNG.
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let data = Data(base64Encoded: pngBase64)!
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    private static func writeSampleBundle() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "<!doctype html><title>sample</title>".write(
            to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8
        )
        return dir
    }
}
