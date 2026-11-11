import AppKit
import SwiftUI
import WebKit

/// The pure "which preview do we show" rule for a review ask's `html_bundle`
/// card (HAIL-49 contract: "both: the agent's preview when present, else the
/// agent's size, else 1280 px desktop"; amendment A1: "render at the card's
/// real size" - the no-preview fallback and `preview.html` no longer render
/// at a fixed 1280x800 / 1200x630, they render at the live card size, so 1
/// CSS px = 1 pt and nothing is scaled afterwards). Free of any loader state
/// or live artifact, so it is testable in isolation - mirrors
/// `ArtifactDisplayRule` above, one level down (which small-card content to
/// render, not which display mode the whole artifact gets).
enum ArtifactPreviewPlan: Equatable {
    /// No preview, no viewport: render the entry page at the card's own
    /// width and height and show it filling the card, top-aligned. `true`
    /// when the page's own content is taller than the card (measured after
    /// render, `document.scrollHeight` vs. the card height) - only then does
    /// the card show the soft bottom fade; a page that already fits gets no
    /// fade (amendment A1: "soft fade only if the page is taller than the
    /// card").
    case defaultDesktop(renderSize: CGSize, isTruncated: Bool)
    /// The agent's own viewport, narrower than tall (a phone screen): shown
    /// centred in a phone-shaped frame at the card's (grown) height, not
    /// stretched.
    case viewportPhone(renderSize: CGSize)
    /// The agent's own viewport, not narrower than tall: rendered at the
    /// agent's own size, then scaled to the card's width, top-aligned,
    /// cropped to the card height with a fade.
    case viewportFull(renderSize: CGSize)
    /// The agent's own `preview.html`: rendered at the card's own width and
    /// height (amendment A1 - superseded the earlier fixed 1200x630), shown
    /// at that same size with nothing to scale.
    case previewHTML(renderSize: CGSize)
    /// The agent's own `preview.png`/`.jpg`: scaled to the card's width,
    /// top-aligned, cropped to the card height with a fade - the same
    /// treatment as `viewportFull`, since its aspect ratio is the agent's
    /// own and may not match the card's.
    case previewImage

    /// The small card's fixed height (docs/stories/HAIL-25.md's original 280
    /// pt) - every plan except `.viewportPhone` renders and displays at this
    /// height.
    static let cardHeight: CGFloat = 280
    /// The card's height when it holds a phone-shaped viewport (amendment
    /// A1: "the card grows to 420 pt tall for phone previews so the screen
    /// reads better").
    static let phoneCardHeight: CGFloat = 420
    /// The card width assumed before the view has measured its own real
    /// width (first layout pass) - a typical case pane content width, close
    /// enough that the very first render rarely needs a second pass.
    static let defaultCardWidth: CGFloat = 620

    /// Order: preview, else viewport, else the card's own size (contract).
    /// `cardWidth` is the card's live, measured width in points; `isTruncated`
    /// is only known after rendering `.defaultDesktop`, so callers choosing a
    /// plan to render pass `false` and correct it afterwards (see
    /// `ArtifactPreviewLoader`).
    static func choose(
        viewport: ViewportSize?, preview: ArtifactPreviewInfo?, cardWidth: CGFloat, isTruncated: Bool = false
    ) -> ArtifactPreviewPlan {
        if let preview {
            return preview.kind == .html
                ? .previewHTML(renderSize: CGSize(width: cardWidth, height: cardHeight))
                : .previewImage
        }
        if let viewport {
            let size = CGSize(width: CGFloat(viewport.width), height: CGFloat(viewport.height))
            return size.width < size.height ? .viewportPhone(renderSize: size) : .viewportFull(renderSize: size)
        }
        return .defaultDesktop(renderSize: CGSize(width: cardWidth, height: cardHeight), isTruncated: isTruncated)
    }

    /// The size to render the bundle's entry (or `preview.html`) page at,
    /// off-screen, before any snapshot or crop - nil for `.previewImage`,
    /// which is already an image with nothing to render.
    var renderSize: CGSize? {
        switch self {
        case .defaultDesktop(let size, _), .viewportPhone(let size), .viewportFull(let size), .previewHTML(let size):
            return size
        case .previewImage:
            return nil
        }
    }

    /// Whether this plan renders `preview.html` (in place of `entry`) rather
    /// than the bundle's own entry page.
    var isPreviewHTML: Bool {
        if case .previewHTML = self { return true }
        return false
    }

    /// The card's height for this plan (amendment A1: only a phone viewport
    /// grows it).
    var cardHeightForDisplay: CGFloat {
        if case .viewportPhone = self { return Self.phoneCardHeight }
        return Self.cardHeight
    }

    /// Buckets a live width measurement to the nearest 40 pt (amendment A1:
    /// "re-render when the card width changes by more than ~40 pt
    /// (debounced), cache per case+revision+width bucket"). Driving the
    /// loader's cache key and its `.task(id:)` off this bucket, rather than
    /// the raw width, is what gives both behaviours for free: a width change
    /// smaller than the bucket does not start a new task, and a bucket
    /// already rendered for this case+revision is served from cache.
    static func widthBucket(_ width: CGFloat, step: CGFloat = 40) -> Int {
        guard step > 0 else { return Int(width) }
        return Int((width / step).rounded()) * Int(step)
    }
}

/// The pure sizing math the card's content view uses to lay out a rendered
/// snapshot within the card's fixed width and height cap - free of any live
/// image or view, so it is testable without rendering anything.
enum ArtifactCardGeometry {
    /// `.viewportPhone`: the displayed size when the image fits inside the
    /// card's height, preserving aspect ratio, so the phone frame never
    /// stretches.
    static func fitHeight(imageSize: CGSize, cardHeight: CGFloat) -> CGSize {
        guard imageSize.height > 0 else { return .zero }
        let scale = cardHeight / imageSize.height
        return CGSize(width: imageSize.width * scale, height: cardHeight)
    }
}

/// What the case pane's preview card has to show for one case's latest
/// revision (docs/stories/HAIL-25.md).
enum ArtifactPreviewState {
    case loading
    case screenshot(NSImage)
    /// An `html_bundle` on a review ask (today's small preview, HAIL-25): a
    /// static, off-screen-rendered snapshot, cached per case, revision and
    /// card width bucket (amendment A1), plus the plan (HAIL-49) that
    /// decided what was rendered and how the card should show it.
    case htmlSnapshot(NSImage, plan: ArtifactPreviewPlan)
    /// A staged `markdown` artifact (HAIL-33, full-width reading mode added
    /// HAIL-45): the full text, rendered inline by `MarkdownView` at pane
    /// width - never the small card.
    case markdown(String)
    /// A staged `screenshots` artifact (HAIL-40): the first image plus the
    /// total count, for the card's "1 / N" badge - the full flip-through
    /// experience is the review workspace's job, not this small card.
    case screenshots(NSImage, count: Int)
    /// A staged `diagram` artifact (HAIL-141): a scaled, off-screen-rendered
    /// snapshot of the diagram, so the card needs no separate preview file.
    case diagramSnapshot(NSImage)
    /// HTML preview is off in Settings, or the isolation self-check failed,
    /// or the artifact could not be read.
    case unavailable
    /// The bundle's off-screen render did not finish within
    /// `ArtifactPreviewLoader.renderTimeoutSeconds` (HAIL-55: a page whose
    /// own script never yields - or any other WebKit stall - must not spin
    /// the still card forever). Distinct from `.unavailable`: this is a
    /// timing problem, not a settings/isolation one, so the card offers its
    /// own "Preview is taking long" copy rather than "preview off".
    case timedOut
}

/// One in-memory snapshot per case, revision and card-width bucket
/// (docs/stories/HAIL-25.md: "Cache the snapshot per case and revision";
/// amendment A1: "cache per case+revision+width bucket", since the render
/// itself now depends on the card's live width) - rendering an `html_bundle`
/// off-screen is the expensive step this avoids repeating; `.shared` is the
/// production default, a fresh instance keeps tests isolated from each
/// other. Caches the plan alongside the image, not just the image: a
/// `.defaultDesktop` plan carries the "is this page taller than the card"
/// flag learned at render time, which a cache hit must replay too.
@MainActor
final class ArtifactPreviewCache {
    static let shared = ArtifactPreviewCache()

    private struct Entry {
        let image: NSImage
        let plan: ArtifactPreviewPlan
    }

    private var entries: [String: Entry] = [:]

    init() {}

    func entry(caseId: String, revision: Int, widthBucket: Int) -> (image: NSImage, plan: ArtifactPreviewPlan)? {
        guard let entry = entries[key(caseId, revision, widthBucket)] else { return nil }
        return (entry.image, entry.plan)
    }

    func store(_ image: NSImage, plan: ArtifactPreviewPlan, caseId: String, revision: Int, widthBucket: Int) {
        entries[key(caseId, revision, widthBucket)] = Entry(image: image, plan: plan)
    }

    private func key(_ caseId: String, _ revision: Int, _ widthBucket: Int) -> String {
        "\(caseId):\(revision):\(widthBucket)"
    }
}

/// Loads one case's artifact preview (docs/stories/HAIL-25.md): a screenshot
/// loads and displays directly; an `html_bundle` renders off-screen, in the
/// same isolated `WKWebView` configuration the review viewer uses
/// (`IsolationGate`/`HTMLIsolation`), then is captured to a static image and
/// cached.
@MainActor
final class ArtifactPreviewLoader: ObservableObject {
    @Published private(set) var state: ArtifactPreviewState = .loading

    private let client: KnockClient
    private let isolationGate: IsolationGate
    private let cache: ArtifactPreviewCache
    private let environment: [String: String]
    private let renderTimeoutSeconds: Double

    /// HAIL-55 contract: "after a timeout (about 10 s)". A short bound is
    /// injectable so tests can prove the timeout path without waiting 10
    /// real seconds - see `ArtifactPreviewLoaderTests`.
    static let defaultRenderTimeoutSeconds: Double = 10

    init(
        client: KnockClient, isolationGate: IsolationGate = .shared, cache: ArtifactPreviewCache = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        renderTimeoutSeconds: Double = ArtifactPreviewLoader.defaultRenderTimeoutSeconds
    ) {
        self.client = client
        self.isolationGate = isolationGate
        self.cache = cache
        self.environment = environment
        self.renderTimeoutSeconds = renderTimeoutSeconds
    }

    /// `caseKind` defaults to `.review` (today's small-card behaviour, and
    /// what every pre-HAIL-45 test call site still expects): only a
    /// question ask's `html_bundle` switches to the live reading mode - see
    /// `ArtifactDisplayRule`. `cardWidth` is the card's own live, measured
    /// width in points (amendment A1); it defaults to a typical width so
    /// every pre-A1 call site still works, but the real card always passes
    /// its own measured value - see `ArtifactPreviewCard`.
    func load(
        caseId: String, revision: Int, caseKind: Case.Kind = .review,
        cardWidth: CGFloat = ArtifactPreviewPlan.defaultCardWidth
    ) async {
        state = .loading
        do {
            let result = try await client.artifactPath(caseId: caseId, revision: revision)
            switch result.kind {
            case .screenshot:
                guard let image = NSImage(contentsOfFile: result.root) else {
                    state = .unavailable
                    return
                }
                state = .screenshot(image)
            case .markdown:
                guard let text = try? String(contentsOfFile: result.root, encoding: .utf8) else {
                    state = .unavailable
                    return
                }
                state = .markdown(text)
            case .screenshots:
                guard let items = result.items, let first = items.first,
                      let image = NSImage(contentsOfFile: first.path) else {
                    state = .unavailable
                    return
                }
                state = .screenshots(image, count: items.count)
            case .diagram:
                guard let text = try? String(contentsOfFile: result.root, encoding: .utf8) else {
                    state = .unavailable
                    return
                }
                await isolationGate.runSelfCheckIfNeeded()
                guard isolationGate.htmlPreviewAvailable, let configuration = isolationGate.makeConfiguration() else {
                    state = .unavailable
                    return
                }
                do {
                    let format = DiagramFormat(pathExtension: (result.root as NSString).pathExtension)
                    let directory = try DiagramPage.makeTempDirectory()
                    let entry = try DiagramPage.materialize(
                        source: text, format: format,
                        mermaidJSURL: MermaidResource.mermaidJSURL(),
                        into: directory
                    )
                    let renderSize = CGSize(width: cardWidth, height: ArtifactPreviewPlan.cardHeight)
                    let renderResult = await withTimeout(seconds: renderTimeoutSeconds) {
                        await Self.renderDiagramSnapshot(
                            entryURL: entry.resolvingSymlinksInPath(),
                            directoryURL: directory.resolvingSymlinksInPath(),
                            configuration: configuration, size: renderSize
                        )
                    }
                    guard let renderResult else {
                        state = .timedOut
                        return
                    }
                    guard let image = renderResult else {
                        state = .unavailable
                        return
                    }
                    state = .diagramSnapshot(image)
                } catch {
                    state = .unavailable
                }
            case .htmlBundle:
                var plan = ArtifactPreviewPlan.choose(viewport: result.viewport, preview: result.preview, cardWidth: cardWidth)
                let widthBucket = ArtifactPreviewPlan.widthBucket(cardWidth)
                if let cached = cache.entry(caseId: caseId, revision: revision, widthBucket: widthBucket) {
                    state = .htmlSnapshot(cached.image, plan: cached.plan)
                    return
                }
                await isolationGate.runSelfCheckIfNeeded()
                let enabled = HTMLPreviewSettings.isEnabled(
                    isolationPassed: isolationGate.htmlPreviewAvailable, environment: environment
                )
                guard enabled else {
                    state = .unavailable
                    return
                }
                // A preview.png/.jpg (HAIL-49) is already an image: load it
                // directly, the same way a `screenshot` artifact does, with
                // no WKWebView render step.
                if case .previewImage = plan {
                    guard let previewPath = result.preview?.path,
                          let image = NSImage(contentsOfFile: previewPath) else {
                        state = .unavailable
                        return
                    }
                    cache.store(image, plan: plan, caseId: caseId, revision: revision, widthBucket: widthBucket)
                    state = .htmlSnapshot(image, plan: plan)
                    return
                }
                guard let configuration = isolationGate.makeConfiguration() else {
                    state = .unavailable
                    return
                }
                // Resolve symlinks (e.g. /tmp -> /private/tmp), as
                // `ReviewViewModel` does: the read-access grant and the
                // subresource URLs must name the same path. A preview.html
                // (HAIL-49) renders in place of entry, inside the same
                // bundle directory, so its own relative assets still resolve.
                let renderPath = plan.isPreviewHTML ? (result.preview?.path ?? result.entry) : result.entry
                let entryURL = URL(fileURLWithPath: renderPath).resolvingSymlinksInPath()
                let directoryURL = URL(fileURLWithPath: result.root).resolvingSymlinksInPath()
                guard let renderSize = plan.renderSize else {
                    state = .unavailable
                    return
                }
                // HAIL-55: `evaluateJavaScript`/`takeSnapshot` inside
                // `renderSnapshot` are callback-based - WebKit gives them no
                // timeout of their own, so a page whose script never yields
                // (or any other WebKit stall) would otherwise leave `state`
                // at `.loading` forever. Bounded here; the outer `nil` means
                // the timeout fired, the inner `nil` means `renderSnapshot`
                // itself finished but had nothing to show.
                let renderResult = await withTimeout(seconds: renderTimeoutSeconds) {
                    await Self.renderSnapshot(
                        entryURL: entryURL, directoryURL: directoryURL, configuration: configuration, size: renderSize
                    )
                }
                guard let renderResult else {
                    state = .timedOut
                    return
                }
                guard let rendered = renderResult else {
                    state = .unavailable
                    return
                }
                // Only `.defaultDesktop` carries an `isTruncated` flag - fold
                // in what the render just measured (amendment A1: the fade
                // shows only when the page is actually taller than the card).
                if case .defaultDesktop(let size, _) = plan {
                    plan = .defaultDesktop(renderSize: size, isTruncated: rendered.isTruncated)
                }
                cache.store(rendered.image, plan: plan, caseId: caseId, revision: revision, widthBucket: widthBucket)
                state = .htmlSnapshot(rendered.image, plan: plan)
            }
        } catch {
            state = .unavailable
        }
    }

    /// Renders `entryURL` in a hidden `WKWebView`, at `size` (HAIL-49: the
    /// plan's own render size - amendment A1: the card's own live width and
    /// height by default, the agent's declared viewport, or `preview.html`
    /// at that same card size), and returns a static snapshot of it plus
    /// whether the page's own content is taller than what was rendered
    /// (`document.scrollHeight` vs. `size.height` - amendment A1: "the fade
    /// shows only if the page is taller than the card"; only `.defaultDesktop`
    /// uses this, but it costs nothing extra to measure for every render).
    /// Never added to a window: `WebViewCaptureControllerTests` already
    /// proves `takeSnapshot` works on a standalone, off-screen `WKWebView`.
    private static func renderSnapshot(
        entryURL: URL, directoryURL: URL, configuration: WKWebViewConfiguration, size: CGSize
    ) async -> (image: NSImage, isTruncated: Bool)? {
        let webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        HTMLIsolation.load(entry: entryURL, directory: directoryURL, into: webView)
        for _ in 0..<Self.maxLoadAttempts {
            // The outer timeout race (`withTimeout`) cancels the losing side
            // rather than stopping it - WebKit's callback APIs give it no
            // way to. Checking cancellation here at least stops the poll
            // loop and the load itself early, instead of silently finishing
            // a render nobody will ever look at (HAIL-55: "the review canvas
            // stays responsive... no main-thread stalls from... snapshotting").
            if Task.isCancelled {
                webView.stopLoading()
                return nil
            }
            try? await Task.sleep(nanoseconds: Self.loadPollDelayNanoseconds)
            if !webView.isLoading { break }
        }
        guard !Task.isCancelled else {
            webView.stopLoading()
            return nil
        }
        let scrollHeight = try? await webView.evaluateJavaScript(
            "Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)"
        )
        let isTruncated = ((scrollHeight as? NSNumber)?.doubleValue ?? 0) > Double(size.height) + 1
        guard let image = await withCheckedContinuation({ continuation in
            webView.takeSnapshot(with: nil) { image, _ in
                continuation.resume(returning: image)
            }
        }) else { return nil }
        return (image, isTruncated)
    }

    /// Renders a diagram wrapper (HAIL-141) off-screen and returns a snapshot.
    /// Mermaid draws asynchronously after the page loads, so this polls for
    /// the wrapper's `document.title` sentinel (`DiagramPage.titleSentinel`)
    /// before snapping, unlike `renderSnapshot` which only waits for the page
    /// load. The outer `withTimeout` (above) still bounds the whole render.
    private static func renderDiagramSnapshot(
        entryURL: URL, directoryURL: URL, configuration: WKWebViewConfiguration, size: CGSize
    ) async -> NSImage? {
        let webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        HTMLIsolation.load(entry: entryURL, directory: directoryURL, into: webView)
        for _ in 0..<maxDiagramLoadAttempts {
            if Task.isCancelled {
                webView.stopLoading()
                return nil
            }
            if webView.title == DiagramPage.titleSentinel { break }
            try? await Task.sleep(nanoseconds: loadPollDelayNanoseconds)
        }
        guard !Task.isCancelled else {
            webView.stopLoading()
            return nil
        }
        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private static let maxLoadAttempts = 40
    private static let maxDiagramLoadAttempts = 120
    private static let loadPollDelayNanoseconds: UInt64 = 50_000_000
}

/// The case pane's artifact preview (docs/stories/HAIL-25.md; full-width
/// reading modes added HAIL-45): sits between the Need/Why block and the
/// options. A screenshot, a screenshots set, a review ask's `html_bundle`,
/// or an unavailable preview render as today's small card - see
/// `cardBody`, reusing the M4 artifact area's radius and stroke
/// (`Theme.Radius.card`/`Theme.Stroke.card` - see the Choices ledger). A
/// markdown write-up renders full pane width instead (`ArtifactDisplayRule`)
/// - see `markdownReadingBody`. Every `html_bundle` is the still card (never
/// a live page that catches the scroll wheel); tapping it opens the review
/// workspace, as does the markdown view's "Open full size" link.
struct ArtifactPreviewCard: View {
    let caseId: String
    let revision: Int
    let caseKind: Case.Kind
    let client: KnockClient
    let onOpen: () -> Void
    /// A click inside the card that does not open it: the write-up's fold
    /// toggle (HAIL-83).
    var onInteract: () -> Void = {}
    /// The split pane (HAIL-71) shows "v<N> · latest" as a chip beside the label.
    var showsLatestChip = false
    /// The card's content only, for a host that has its own header, border and "Open full size" (WAG-300: the
    /// artifact box). Same image loading and the same body; no strip, no frame. The screens count moves into
    /// the pager badge so nothing the strip said is lost.
    var chromeless = false
    /// With `chromeless`: the image fits the height it gets, centred, instead of the 280 pt card cap.
    var fillsHeight = false

    @StateObject private var loader: ArtifactPreviewLoader

    /// The card's own live, measured width in points (amendment A1: "the
    /// card knows its width in points (measure it, like HAIL-45's
    /// onGeometryChange)"). `nil` until the first layout pass; `taskId`
    /// gates the load on this being known, so the render never starts at a
    /// guessed width.
    @State private var cardWidth: CGFloat?
    /// When the current render began, for the loading timer (HAIL-66).
    @State private var loadStartedAt = Date()

    init(
        caseId: String, revision: Int, caseKind: Case.Kind, client: KnockClient,
        showsLatestChip: Bool = false,
        chromeless: Bool = false,
        fillsHeight: Bool = false,
        onOpen: @escaping () -> Void,
        onInteract: @escaping () -> Void = {}
    ) {
        self.chromeless = chromeless
        self.fillsHeight = fillsHeight
        self.onInteract = onInteract
        self.showsLatestChip = showsLatestChip
        self.caseId = caseId
        self.revision = revision
        self.caseKind = caseKind
        self.client = client
        self.onOpen = onOpen
        _loader = StateObject(wrappedValue: ArtifactPreviewLoader(client: client))
    }

    var body: some View {
        Group {
            switch loader.state {
            case .markdown(let text):
                markdownReadingBody(text)
            default:
                cardBody
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { cardWidth = $0 }
        .task(id: taskId) {
            guard let cardWidth else { return }
            loadStartedAt = Date()
            await loader.load(caseId: caseId, revision: revision, caseKind: caseKind, cardWidth: cardWidth)
        }
    }

    /// Drives the load off the case, revision and the card's width *bucket*
    /// (amendment A1), not the raw width: `ArtifactPreviewPlan.widthBucket`
    /// rounds to the nearest 40 pt, so a `.task(id:)` keyed on it only
    /// restarts the render when the width actually crosses a bucket boundary
    /// - the debounce the contract asks for, for free from SwiftUI's own
    /// "cancel and restart on id change" behaviour. `"pending"` before the
    /// first geometry read keeps the loader in `.loading` rather than
    /// rendering at a guessed width.
    private var taskId: String {
        let bucket = cardWidth.map { String(ArtifactPreviewPlan.widthBucket($0)) } ?? "pending"
        return "\(caseId):\(revision):\(bucket)"
    }

    /// The card's height for whatever is currently loaded - 280 pt for every
    /// mode except a phone-shaped agent viewport, which grows the card to
    /// 420 pt (amendment A1: "the card grows to 420 pt tall for phone
    /// previews so the screen reads better").
    private var effectiveCardHeight: CGFloat {
        if case .htmlSnapshot(_, let plan) = loader.state {
            return plan.cardHeightForDisplay
        }
        return ArtifactPreviewPlan.cardHeight
    }

    // MARK: Card mode (screenshot, screenshots, a review ask's html_bundle,
    // loading, unavailable) - docs/stories/HAIL-25.md's original 280 pt card,
    // unchanged by HAIL-45.

    @ViewBuilder
    private var cardBody: some View {
        if chromeless { chromelessBody } else { framedBody }
    }

    /// The still body alone: the box around it gives the header, the border and "Open full size".
    private var chromelessBody: some View {
        cardContent
            .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : effectiveCardHeight)
            .background(Theme.Colors.list)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen).pointerCursor()
    }

    private var framedBody: some View {
        // One framed card with a header strip (operator, 29 Sep: "why here
        // the preview doesn't have that button top right to open it in
        // full"; Pen "Ask pane · prototype card with the same header").
        VStack(spacing: 0) {
            AttachmentCardHeader(
                icon: cardHeader.icon, label: cardHeader.label,
                meta: showsLatestChip ? Self.metaWithoutVersion(cardHeader.meta, revision: revision) : cardHeader.meta,
                chip: showsLatestChip ? "v\(revision) · latest" : nil, onOpen: onOpen
            )
            cardContent
                .frame(maxWidth: .infinity, maxHeight: effectiveCardHeight)
                .background(Theme.Colors.list)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen).pointerCursor()
        }
        .background(Theme.Colors.win)
        .cornerRadius(Theme.Radius.card)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(Theme.Stroke.card.color, lineWidth: Theme.Stroke.card.width)
        )
    }

    /// "1 / 3", and in the box "1 / 3 screens", since the box has no strip to say the count.
    nonisolated static func pagerLabel(count: Int, chromeless: Bool) -> String {
        chromeless ? "1 / \(count) screens" : "1 / \(count)"
    }

    /// "v2 · still preview" becomes "still preview"; "v2" becomes "".
    nonisolated static func metaWithoutVersion(_ meta: String, revision: Int) -> String {
        let prefix = "v\(revision)"
        guard meta.hasPrefix(prefix) else { return meta }
        return String(meta.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ·"))
    }

    private var cardHeader: (icon: String, label: String, meta: String) {
        switch loader.state {
        case .screenshot: return ("photo", "SCREENSHOT FROM THE AGENT", "v\(revision)")
        case .screenshots(_, let count): return ("photo.on.rectangle", "SCREENSHOTS FROM THE AGENT", "v\(revision) · \(count) screens")
        case .diagramSnapshot: return ("flowchart", "DIAGRAM FROM THE AGENT", "v\(revision)")
        case .unavailable: return ("macwindow", "PROTOTYPE FROM THE AGENT", "v\(revision) · preview off")
        case .timedOut: return ("clock.badge.exclamationmark", "PROTOTYPE FROM THE AGENT", "v\(revision) · preview timed out")
        default: return ("macwindow", "PROTOTYPE FROM THE AGENT", "v\(revision) · still preview")
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        switch loader.state {
        case .loading:
            LoadingStatus(label: "Rendering preview", since: loadStartedAt)
                .frame(maxWidth: .infinity, minHeight: 160)
        case .screenshot(let image):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        case .diagramSnapshot(let image):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        case .htmlSnapshot(let image, let plan):
            htmlSnapshotContent(image: image, plan: plan)
        case .screenshots(let image, let count):
            ZStack(alignment: .topTrailing) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                Text(Self.pagerLabel(count: count, chromeless: chromeless))
                    .knockTextStyle(Theme.Typography.badgeLabel11w500)
                    .foregroundColor(Theme.Colors.win)
                    .padding(EdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 7))
                    .background(Theme.Colors.ink.opacity(0.65))
                    .cornerRadius(Theme.Radius.chip)
                    .padding(8)
            }
        case .unavailable:
            Image(systemName: "lock.slash")
                .font(.system(size: 16))
                .foregroundColor(Theme.Colors.ink2)
                .frame(maxWidth: .infinity, minHeight: 120)
        case .timedOut:
            timedOutContent
        // `body` routes both to their own reading view above; `cardContent`
        // never renders for either, so this is unreachable in practice.
        case .markdown:
            EmptyView()
        }
    }

    /// HAIL-55 contract: "after a timeout (about 10 s) the still card...
    /// show a clear fallback ('Preview is taking long. Open full size')
    /// instead of the spinner." The whole card is already tappable
    /// (`cardBody`'s `onTapGesture`), so this just states what happened.
    private var timedOutContent: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                PixelStatusGrid(pattern: .still(0.3), color: Theme.Colors.ink3, cell: 4)
                Text("Preview is taking long.")
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.ink2)
                ElapsedTimer(since: loadStartedAt)
            }
            Text("Open full size")
                .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                .foregroundColor(Theme.Colors.ink)
                .underline()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    // MARK: html_bundle card content (HAIL-49, amendment A1): which look the
    // rendered snapshot gets, decided by `ArtifactPreviewPlan` - the
    // no-preview fallback shows at its own exact render size (already the
    // card's size) with a fade only when the page ran taller than the card;
    // a full-size agent viewport and a `preview.png`/`.jpg` fill the card's
    // width, cropped to height with a fade, since their aspect ratio is the
    // agent's own; a phone-shaped agent viewport gets the phone frame; a
    // `preview.html` is already exactly the card's size, so it needs no
    // scaling or cropping at all.

    @ViewBuilder
    private func htmlSnapshotContent(image: NSImage, plan: ArtifactPreviewPlan) -> some View {
        switch plan {
        case .defaultDesktop(_, let isTruncated):
            cardSizedContent(image: image, showFade: isTruncated)
        case .viewportFull, .previewImage:
            fillWidthCroppedContent(image: image)
        case .viewportPhone:
            phoneFramedContent(image: image)
        case .previewHTML:
            fitWidthContent(image: image)
        }
    }

    /// Knock's own fallback (amendment A1): rendered off-screen at exactly
    /// the card's own width and height, so this is a 1:1 display of that
    /// render, top-aligned - nothing left to scale or crop. `showFade` is
    /// `true` only when the page's own content ran taller than the card
    /// (measured at render time), so the fade reads as "there is more below"
    /// rather than an arbitrary decoration.
    private func cardSizedContent(image: NSImage, showFade: Bool) -> some View {
        ZStack(alignment: .bottom) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: effectiveCardHeight, alignment: .top)
                .clipped()
            if showFade {
                LinearGradient(
                    colors: [Theme.Colors.list.opacity(0), Theme.Colors.list.opacity(0.85)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 56)
                .allowsHitTesting(false)
            }
        }
    }

    /// A full-size agent viewport, or a `preview.png`/`.jpg`: fills the
    /// card's width, top-aligned, clipped to the card's height, with a soft
    /// fade at the bottom so the crop reads as intentional - both render (or
    /// were authored) at the agent's own aspect ratio, which need not match
    /// the card's. No side bands.
    private func fillWidthCroppedContent(image: NSImage) -> some View {
        ZStack(alignment: .bottom) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: effectiveCardHeight, alignment: .top)
                .clipped()
            LinearGradient(
                colors: [Theme.Colors.list.opacity(0), Theme.Colors.list.opacity(0.85)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 56)
            .allowsHitTesting(false)
        }
    }

    /// A narrow agent viewport (a phone screen): centred in a phone-shaped
    /// frame sized to the card's (grown) height, preserving the viewport's
    /// own aspect ratio rather than stretching it to fill the card.
    private func phoneFramedContent(image: NSImage) -> some View {
        let displaySize = ArtifactCardGeometry.fitHeight(imageSize: image.size, cardHeight: effectiveCardHeight)
        return HStack {
            Spacer(minLength: 0)
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: displaySize.width, height: displaySize.height)
                .cornerRadius(Theme.Radius.card)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .stroke(Theme.Stroke.card.color, lineWidth: Theme.Stroke.card.width)
                )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: effectiveCardHeight)
    }

    /// The agent's own `preview.html` (amendment A1): rendered off-screen at
    /// exactly the card's own width and height, so this too is a 1:1 display
    /// - shown as is, never cropped, since it was built for this size.
    private func fitWidthContent(image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: effectiveCardHeight)
    }

    // MARK: Markdown reading mode (HAIL-45 AC): the full write-up, inline,
    // at the pane's full content width, with the app's own typography via
    // `MarkdownView` - no 280 pt cap, no excerpt. `MarkdownView` lays out as
    // a plain `VStack`, so it scrolls with the rest of the pane's own
    // `ScrollView` rather than carrying a nested one of its own.

    private func markdownReadingBody(_ text: String) -> some View {
        MarkdownDocumentCard(
            text: text, revision: revision, showsLatestChip: showsLatestChip, onOpen: onOpen, onInteract: onInteract)
    }

}


/// The header strip every attachment card in the ask shares (Pen "Ask pane ·
/// inline write-up as a document"): what the agent attached, its version,
/// and an always-visible "Open full size".
struct AttachmentCardHeader: View {
    let icon: String
    let label: String
    let meta: String
    /// "v2 · latest": a blue chip after the label (HAIL-71).
    var chip: String? = nil
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(Theme.Colors.ink2)
            Text(label)
                .knockTextStyle(Theme.Typography.labelCaps10_5w600)
                .foregroundColor(Theme.Colors.ink3)
                .lineLimit(1)
            if let chip {
                Text(chip)
                    .lineLimit(1)
                    .fixedSize()
                    .knockTextStyle(Theme.Typography.monoMetaRow10_5w600)
                    .foregroundColor(Theme.Colors.ds)
                    .padding(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                    .background(Theme.Colors.dsSoft)
                    .cornerRadius(4)
            }
            if !meta.isEmpty {
                Text(meta)
                    .knockTextStyle(Theme.Typography.monoMetaRow10_5w400)
                    .foregroundColor(Theme.Colors.ink3)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: onOpen) {
                HStack(spacing: 5) {
                    Text("Open full size")
                        .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                        .lineLimit(1)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(Theme.Colors.ink2)
                .padding(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                .background(Theme.Colors.win)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.Colors.line2, lineWidth: 1))
            }
            .buttonStyle(.plain).pointerCursor()
            .fixedSize()
        }
        .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.list)
        .overlay(Rectangle().fill(Theme.Colors.line).frame(height: 1), alignment: .bottom)
    }
}

/// The agent's Markdown write-up as its own document card (operator, 29
/// Sep: "redesign of the inline .md separating it clearly from the needs
/// from you, why i can't decide"). Long write-ups fold at
/// `collapsedHeight`; "Read the whole write-up" expands them in place - no
/// scroll box inside the ask.
struct MarkdownDocumentCard: View {
    let text: String
    let revision: Int
    var showsLatestChip = false
    let onOpen: () -> Void
    var onInteract: () -> Void = {}
    @State private var isExpanded = false
    @State private var naturalHeight: CGFloat = 0

    nonisolated static let collapsedHeight: CGFloat = 340

    /// "3 min read", at about 220 words a minute, never below 1.
    nonisolated static func readingTime(for text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        return "\(max(1, Int((Double(words) / 220).rounded())) ) min read"
    }

    private var isLong: Bool { naturalHeight > Self.collapsedHeight + 40 }

    var body: some View {
        VStack(spacing: 0) {
            AttachmentCardHeader(
                icon: "doc.text", label: "WRITE-UP FROM THE AGENT",
                meta: showsLatestChip ? Self.readingTime(for: text) : "v\(revision) · \(Self.readingTime(for: text))",
                chip: showsLatestChip ? "v\(revision) · latest" : nil, onOpen: onOpen
            )
            MarkdownView(text: text)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { naturalHeight = $0 }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: isLong && !isExpanded ? Self.collapsedHeight : nil, alignment: .top)
                .clipped()
                .overlay(alignment: .bottom) {
                    if isLong && !isExpanded {
                        LinearGradient(colors: [Theme.Colors.win.opacity(0), Theme.Colors.win], startPoint: .top, endPoint: .bottom)
                            .frame(height: 56)
                            .allowsHitTesting(false)
                    }
                }
                .padding(EdgeInsets(top: 16, leading: 24, bottom: isLong ? 4 : 18, trailing: 24))
            if isLong {
                HStack(spacing: 10) {
                    Rectangle().fill(Theme.Colors.line).frame(height: 1)
                    Button {
                        isExpanded.toggle()
                        onInteract()
                    } label: {
                        HStack(spacing: 5) {
                            Text(isExpanded ? "Show less" : "Read the whole write-up")
                                .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(Theme.Colors.ink2)
                        .padding(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
                        .overlay(Capsule().stroke(Theme.Colors.line2, lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain).pointerCursor()
                    .fixedSize()
                    Rectangle().fill(Theme.Colors.line).frame(height: 1)
                }
                .padding(EdgeInsets(top: 4, leading: 24, bottom: 14, trailing: 24))
            }
        }
        .background(Theme.Colors.win)
        .cornerRadius(Theme.Radius.card)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(Theme.Stroke.card.color, lineWidth: Theme.Stroke.card.width)
        )
    }
}
