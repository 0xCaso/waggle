import Testing
import Foundation
@testable import Knock

/// HAIL-40: `artifactPath`'s items JSON for a `screenshots` revision -
/// `root`/`entry` are empty, the ordered blob paths live in `items` instead
/// (daemon/src/store.ts). A free top-level function, not a method on the
/// `@MainActor`-isolated struct below: `FakeKnockServer.onRequest` runs this
/// off the main actor, and a `.map` closure on an actor-isolated method traps
/// at runtime when called from there (verified empirically - the one-line
/// `artifactPathResultJSON` below gets away with it only because it is small
/// enough to be fully inlined).
private func artifactPathScreenshotsResultJSON(itemPaths: [String]) -> String {
    let items = itemPaths.map { #"{"path":"\#($0)"}"# }.joined(separator: ",")
    return #"{"kind":"screenshots","root":"","entry":"","items":[\#(items)]}"#
}

/// `ArtifactPreviewLoader`: the case pane's preview card (docs/stories/
/// HAIL-25.md) - a screenshot loads directly, an `html_bundle` renders
/// off-screen and is cached, and either kind falls back to the "preview off"
/// placeholder when HTML preview is disabled.
@MainActor
struct ArtifactPreviewLoaderTests {
    private func artifactPathResultJSON(kind: String, root: String, entry: String) -> String {
        #"{"kind":"\#(kind)","root":"\#(root)","entry":"\#(entry)"}"#
    }

    /// HAIL-49: an html_bundle result carrying a declared viewport, no preview.
    private func artifactPathResultJSONWithViewport(
        root: String, entry: String, width: Int, height: Int
    ) -> String {
        #"{"kind":"html_bundle","root":"\#(root)","entry":"\#(entry)","viewport":{"width":\#(width),"height":\#(height)}}"#
    }

    /// HAIL-49: an html_bundle result carrying a preview file, no viewport.
    private func artifactPathResultJSONWithPreview(
        root: String, entry: String, previewKind: String, previewPath: String
    ) -> String {
        #"{"kind":"html_bundle","root":"\#(root)","entry":"\#(entry)","preview":{"kind":"\#(previewKind)","path":"\#(previewPath)"}}"#
    }

    private func writeSampleScreenshot() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("shot.png").path
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let data = Data(base64Encoded: pngBase64)!
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    private func writeSampleBundle() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "<!doctype html><body style='background:#fff'>sample</body>".write(
            to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8
        )
        return dir
    }

    /// A bundle whose entry is wide (so a phone-viewport render clearly
    /// differs from it) and which also carries a `preview.html` and a
    /// `preview.png` alongside it (HAIL-49).
    private func writeSampleBundleWithPreview() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "<!doctype html><body style='background:#fff'>page</body>".write(
            to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8
        )
        try "<!doctype html><body style='background:#eee'>card</body>".write(
            to: dir.appendingPathComponent("preview.html"), atomically: true, encoding: .utf8
        )
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        try Data(base64Encoded: pngBase64)!.write(to: dir.appendingPathComponent("preview.png"))
        return dir
    }

    /// A bundle whose page is far taller than any card height - amendment
    /// A1: "soft fade only if the page is taller than the card".
    private func writeSampleBundleTallerThanTheCard() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "<!doctype html><body style='background:#fff;margin:0'><div style='height:2000px'>tall</div></body>".write(
            to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8
        )
        return dir
    }

    private func tempHome() -> [String: String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("knock_preview_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ["KNOCK_HOME": dir.path]
    }

    @Test func loadsAScreenshotDirectly() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let imagePath = try writeSampleScreenshot()
        server.onRequest = { method, id, _ in
            guard let id, method == "artifact.path" else { return nil }
            return jsonRPCOK(id: id, result: artifactPathResultJSON(kind: "screenshot", root: imagePath, entry: ""))
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let loader = ArtifactPreviewLoader(client: client)
        await loader.load(caseId: "c_1", revision: 1)

        guard case .screenshot = loader.state else {
            Issue.record("expected .screenshot, got \(loader.state)")
            return
        }
    }

    @Test func rendersAndCachesAnHtmlBundleSnapshot() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let bundleDir = try writeSampleBundle()
        let entryPath = bundleDir.appendingPathComponent("index.html").path
        var artifactPathCalls = 0
        server.onRequest = { method, id, _ in
            guard let id, method == "artifact.path" else { return nil }
            artifactPathCalls += 1
            return jsonRPCOK(id: id, result: artifactPathResultJSON(kind: "html_bundle", root: bundleDir.path, entry: entryPath))
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let cache = ArtifactPreviewCache()
        let loader = ArtifactPreviewLoader(client: client, cache: cache)
        await loader.load(caseId: "c_2", revision: 1)

        guard case .htmlSnapshot = loader.state else {
            Issue.record("expected .htmlSnapshot, got \(loader.state)")
            return
        }
        let widthBucket = ArtifactPreviewPlan.widthBucket(ArtifactPreviewPlan.defaultCardWidth)
        #expect(cache.entry(caseId: "c_2", revision: 1, widthBucket: widthBucket) != nil, "the rendered snapshot should be cached per case, revision and width bucket")

        // A second load for the same case/revision must reuse the cached
        // snapshot rather than rendering again.
        await loader.load(caseId: "c_2", revision: 1)
        guard case .htmlSnapshot = loader.state else {
            Issue.record("expected .htmlSnapshot again from cache, got \(loader.state)")
            return
        }
    }

    /// HAIL-49: a declared phone-shaped viewport picks `.viewportPhone` and
    /// renders at that size, not the 1280x800 desktop default.
    @Test func rendersAnHtmlBundleAtItsDeclaredPhoneViewport() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let bundleDir = try writeSampleBundle()
        let entryPath = bundleDir.appendingPathComponent("index.html").path
        server.onRequest = { method, id, _ in
            guard let id, method == "artifact.path" else { return nil }
            return jsonRPCOK(
                id: id,
                result: artifactPathResultJSONWithViewport(root: bundleDir.path, entry: entryPath, width: 390, height: 844)
            )
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let loader = ArtifactPreviewLoader(client: client)
        await loader.load(caseId: "c_10", revision: 1)

        guard case .htmlSnapshot(_, let plan) = loader.state else {
            Issue.record("expected .htmlSnapshot, got \(loader.state)")
            return
        }
        #expect(plan == .viewportPhone(renderSize: CGSize(width: 390, height: 844)))
    }

    /// HAIL-49: a `preview.html` renders in place of `entry`, and picks
    /// `.previewHTML`. Amendment A1: at the card's own size, not a fixed
    /// 1200x630 - the loader's default `cardWidth` when the caller does not
    /// pass one.
    @Test func rendersAnHtmlBundlesPreviewHtmlInPlaceOfEntry() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let bundleDir = try writeSampleBundleWithPreview()
        let entryPath = bundleDir.appendingPathComponent("index.html").path
        let previewPath = bundleDir.appendingPathComponent("preview.html").path
        server.onRequest = { method, id, _ in
            guard let id, method == "artifact.path" else { return nil }
            return jsonRPCOK(
                id: id,
                result: artifactPathResultJSONWithPreview(
                    root: bundleDir.path, entry: entryPath, previewKind: "html", previewPath: previewPath
                )
            )
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let loader = ArtifactPreviewLoader(client: client)
        await loader.load(caseId: "c_11", revision: 1)

        guard case .htmlSnapshot(_, let plan) = loader.state else {
            Issue.record("expected .htmlSnapshot, got \(loader.state)")
            return
        }
        #expect(plan == .previewHTML(renderSize: CGSize(width: ArtifactPreviewPlan.defaultCardWidth, height: ArtifactPreviewPlan.cardHeight)))
    }

    /// Amendment A1: the no-preview fallback renders at whatever `cardWidth`
    /// the caller passes, not a fixed 1280x800 desktop size.
    @Test func rendersTheNoPreviewFallbackAtTheGivenCardWidth() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let bundleDir = try writeSampleBundle()
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

        let loader = ArtifactPreviewLoader(client: client)
        await loader.load(caseId: "c_13", revision: 1, cardWidth: 500)

        guard case .htmlSnapshot(_, let plan) = loader.state else {
            Issue.record("expected .htmlSnapshot, got \(loader.state)")
            return
        }
        #expect(plan == .defaultDesktop(renderSize: CGSize(width: 500, height: ArtifactPreviewPlan.cardHeight), isTruncated: false))
    }

    /// Amendment A1: "soft fade only if the page is taller than the card" -
    /// a page taller than the render height is reported truncated.
    @Test func flagsTheNoPreviewFallbackAsTruncatedWhenThePageIsTallerThanTheCard() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let bundleDir = try writeSampleBundleTallerThanTheCard()
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

        let loader = ArtifactPreviewLoader(client: client)
        await loader.load(caseId: "c_14", revision: 1, cardWidth: 500)

        guard case .htmlSnapshot(_, let plan) = loader.state else {
            Issue.record("expected .htmlSnapshot, got \(loader.state)")
            return
        }
        guard case .defaultDesktop(_, let isTruncated) = plan else {
            Issue.record("expected .defaultDesktop, got \(plan)")
            return
        }
        #expect(isTruncated, "a 2000pt-tall page rendered at 280pt should be reported truncated")
    }

    /// Amendment A1: a short page - one that fits inside the card - is not
    /// truncated, so the card shows no bottom fade for it.
    @Test func doesNotFlagTheNoPreviewFallbackAsTruncatedWhenThePageFits() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let bundleDir = try writeSampleBundle()
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

        let loader = ArtifactPreviewLoader(client: client)
        await loader.load(caseId: "c_15", revision: 1, cardWidth: 500)

        guard case .htmlSnapshot(_, let plan) = loader.state else {
            Issue.record("expected .htmlSnapshot, got \(loader.state)")
            return
        }
        guard case .defaultDesktop(_, let isTruncated) = plan else {
            Issue.record("expected .defaultDesktop, got \(plan)")
            return
        }
        #expect(!isTruncated)
    }

    /// Amendment A1: "cache per case+revision+width bucket" - a render at
    /// one width bucket does not satisfy a load at a different bucket, so
    /// the second load renders (and caches) its own entry rather than
    /// reusing the first's wrongly-sized snapshot.
    @Test func rendersASeparateSnapshotPerWidthBucket() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let bundleDir = try writeSampleBundle()
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

        let cache = ArtifactPreviewCache()
        let loader = ArtifactPreviewLoader(client: client, cache: cache)
        await loader.load(caseId: "c_16", revision: 1, cardWidth: 500)
        guard case .htmlSnapshot(_, let firstPlan) = loader.state else {
            Issue.record("expected .htmlSnapshot, got \(loader.state)")
            return
        }
        #expect(firstPlan.renderSize == CGSize(width: 500, height: ArtifactPreviewPlan.cardHeight))

        await loader.load(caseId: "c_16", revision: 1, cardWidth: 900)
        guard case .htmlSnapshot(_, let secondPlan) = loader.state else {
            Issue.record("expected .htmlSnapshot, got \(loader.state)")
            return
        }
        #expect(secondPlan.renderSize == CGSize(width: 900, height: ArtifactPreviewPlan.cardHeight))

        #expect(cache.entry(caseId: "c_16", revision: 1, widthBucket: ArtifactPreviewPlan.widthBucket(500)) != nil)
        #expect(cache.entry(caseId: "c_16", revision: 1, widthBucket: ArtifactPreviewPlan.widthBucket(900)) != nil)
    }

    /// HAIL-49: a `preview.png` loads directly, with no WKWebView render
    /// step, and picks `.previewImage`.
    @Test func loadsAnHtmlBundlesPreviewImageDirectly() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let bundleDir = try writeSampleBundleWithPreview()
        let entryPath = bundleDir.appendingPathComponent("index.html").path
        let previewPath = bundleDir.appendingPathComponent("preview.png").path
        server.onRequest = { method, id, _ in
            guard let id, method == "artifact.path" else { return nil }
            return jsonRPCOK(
                id: id,
                result: artifactPathResultJSONWithPreview(
                    root: bundleDir.path, entry: entryPath, previewKind: "image", previewPath: previewPath
                )
            )
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let cache = ArtifactPreviewCache()
        let loader = ArtifactPreviewLoader(client: client, cache: cache)
        await loader.load(caseId: "c_12", revision: 1)

        guard case .htmlSnapshot(_, let plan) = loader.state else {
            Issue.record("expected .htmlSnapshot, got \(loader.state)")
            return
        }
        #expect(plan == .previewImage)
        let widthBucket = ArtifactPreviewPlan.widthBucket(ArtifactPreviewPlan.defaultCardWidth)
        #expect(cache.entry(caseId: "c_12", revision: 1, widthBucket: widthBucket) != nil, "the preview image is cached like any other snapshot")
    }

    @Test func fallsBackToUnavailableWhenHtmlPreviewIsOffInSettings() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let bundleDir = try writeSampleBundle()
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

        let env = tempHome()
        HTMLPreviewSettings.setDisabled(true, environment: env)
        defer { HTMLPreviewSettings.setDisabled(false, environment: env) }

        let gate = IsolationGate()
        await gate.runSelfCheckIfNeeded()
        #expect(gate.htmlPreviewAvailable, "the self-check itself should pass on this test host")

        let loader = ArtifactPreviewLoader(client: client, isolationGate: gate, cache: ArtifactPreviewCache(), environment: env)
        await loader.load(caseId: "c_3", revision: 1)

        guard case .unavailable = loader.state else {
            Issue.record("expected .unavailable when the Settings toggle is off, got \(loader.state)")
            return
        }
    }

    /// HAIL-40 contract: "the case pane's preview card shows the first
    /// image with a '1 / N' badge".
    @Test func loadsAScreenshotsArtifactAsItsFirstImagePlusCount() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let firstPath = try writeSampleScreenshot()
        let secondPath = try writeSampleScreenshot()
        server.onRequest = { method, id, _ in
            guard let id, method == "artifact.path" else { return nil }
            return jsonRPCOK(id: id, result: artifactPathScreenshotsResultJSON(itemPaths: [firstPath, secondPath]))
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let loader = ArtifactPreviewLoader(client: client)
        await loader.load(caseId: "c_5", revision: 1)

        guard case .screenshots(_, let count) = loader.state else {
            Issue.record("expected .screenshots, got \(loader.state)")
            return
        }
        #expect(count == 2, "the badge counts every image, not just the first")
    }

    /// HAIL-45: a question ask's `html_bundle` loads the live view itself,
    /// not a rendered-and-cached snapshot - `ArtifactDisplayRuleTests`
    /// covers the mode rule in isolation; this proves the loader actually
    /// applies it.
    /// 29 Sep: the live page caught the scroll wheel, so a question ask's
    /// `html_bundle` is the still card too (click opens it full size).
    @Test func loadsAQuestionAsksHtmlBundleAsTheStillCardToo() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let bundleDir = try writeSampleBundle()
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

        let loader = ArtifactPreviewLoader(client: client)
        await loader.load(caseId: "c_6", revision: 1, caseKind: .question)

        guard case .htmlSnapshot = loader.state else {
            Issue.record("expected the still .htmlSnapshot for a question ask, got \(loader.state)")
            return
        }
    }

    /// HAIL-45: a review ask's `html_bundle` keeps today's small-card
    /// snapshot behaviour explicitly, not just by the default parameter.
    @Test func loadsAReviewAsksHtmlBundleAsTheCachedSnapshotStill() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let bundleDir = try writeSampleBundle()
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

        let loader = ArtifactPreviewLoader(client: client)
        await loader.load(caseId: "c_7", revision: 1, caseKind: .review)

        guard case .htmlSnapshot = loader.state else {
            Issue.record("expected .htmlSnapshot for a review ask, got \(loader.state)")
            return
        }
    }

    /// HAIL-45: the reading mode falls back to `.unavailable` under the
    /// exact same isolation rules as the small-card path (contract: "Keep
    /// isolation rules exactly") - the toggle being off must not somehow
    /// leak the live bundle into the pane anyway.
    @Test func fallsBackToUnavailableForAQuestionAsksHtmlBundleWhenHtmlPreviewIsOff() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let bundleDir = try writeSampleBundle()
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

        let env = tempHome()
        HTMLPreviewSettings.setDisabled(true, environment: env)
        defer { HTMLPreviewSettings.setDisabled(false, environment: env) }

        let gate = IsolationGate()
        await gate.runSelfCheckIfNeeded()
        #expect(gate.htmlPreviewAvailable, "the self-check itself should pass on this test host")

        let loader = ArtifactPreviewLoader(client: client, isolationGate: gate, cache: ArtifactPreviewCache(), environment: env)
        await loader.load(caseId: "c_8", revision: 1, caseKind: .question)

        guard case .unavailable = loader.state else {
            Issue.record("expected .unavailable when the Settings toggle is off, got \(loader.state)")
            return
        }
    }

    /// HAIL-45: a `markdown` artifact loads the same full text regardless of
    /// ask kind - `CasePaneDetailView` always routes it to the full-width
    /// `markdownReadingBody`, never the small card's excerpt.
    @Test func loadsAMarkdownArtifactTheSameWayForEitherAskKind() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("notes.md").path
        let text = "# Plan\n\nA long write-up that should read inline, full width."
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        server.onRequest = { method, id, _ in
            guard let id, method == "artifact.path" else { return nil }
            return jsonRPCOK(id: id, result: artifactPathResultJSON(kind: "markdown", root: path, entry: ""))
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        for caseKind: Case.Kind in [.question, .review] {
            let loader = ArtifactPreviewLoader(client: client)
            await loader.load(caseId: "c_9", revision: 1, caseKind: caseKind)
            guard case .markdown(let loadedText) = loader.state else {
                Issue.record("expected .markdown for \(caseKind), got \(loader.state)")
                return
            }
            #expect(loadedText == text)
        }
    }

    /// A page whose own script never yields (a busy-wait) - the WebContent
    /// process's JS thread is where `evaluateJavaScript`/`takeSnapshot` also
    /// queue their work, so this blocks both indefinitely. HAIL-55: proves
    /// `renderSnapshot`'s two WebKit calls, on their own, never time out -
    /// only `ArtifactPreviewLoader`'s own bound does.
    private func writeSampleBundleThatNeverFinishesScripting() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        <!doctype html><body style='margin:0'>
        <script>
        var start = Date.now();
        while (Date.now() - start < 60000) { /* spin, blocking the JS thread */ }
        </script>
        </body>
        """.write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        return dir
    }

    /// HAIL-55 contract: "after a timeout (about 10 s) the still card...
    /// show a clear fallback... instead of the spinner." A short injected
    /// bound (well under the 60s busy-wait above) keeps this test fast while
    /// still proving the loader settles to `.timedOut` rather than hanging
    /// at `.loading` forever.
    @Test func fallsBackToTimedOutWhenTheRenderNeverFinishesInTime() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let bundleDir = try writeSampleBundleThatNeverFinishesScripting()
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

        let loader = ArtifactPreviewLoader(client: client, renderTimeoutSeconds: 0.5)
        let start = Date()
        await loader.load(caseId: "c_timeout", revision: 1)

        guard case .timedOut = loader.state else {
            Issue.record("expected .timedOut, got \(loader.state)")
            return
        }
        #expect(Date().timeIntervalSince(start) < 30, "must settle at the injected bound, not wait out the page's own 60s busy-loop")
    }

    @Test func fallsBackToUnavailableWhenTheArtifactCannotBeRead() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, _ in
            guard let id, method == "artifact.path" else { return nil }
            return jsonRPCOK(id: id, result: artifactPathResultJSON(kind: "screenshot", root: "/no/such/file.png", entry: ""))
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)

        let loader = ArtifactPreviewLoader(client: client)
        await loader.load(caseId: "c_4", revision: 1)

        guard case .unavailable = loader.state else {
            Issue.record("expected .unavailable for a missing screenshot file, got \(loader.state)")
            return
        }
    }
}
