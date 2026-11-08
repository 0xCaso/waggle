import AppKit
import WebKit

/// Bridges Comment mode's capture step to the live `WKWebView` an
/// `html_bundle` artifact renders in (docs/protocol-mvp.md "capture": "a
/// PNG of the current viewer content (WKWebView `takeSnapshot` or the
/// screenshot image)"). `SandboxedHTMLView` registers its webview here on
/// creation; nothing else touches the webview directly, so the isolation
/// rules (`HTMLIsolation.swift`) stay untouched by this story.
@MainActor
final class WebViewCaptureController: ObservableObject {
    fileprivate weak var webView: WKWebView?
    private var eventMonitor: Any?
    private let captureTimeoutSeconds: Double

    /// HAIL-55: `readPageMetrics`/`snapshot`'s `evaluateJavaScript`/
    /// `takeSnapshot` calls are callback-based - WebKit gives them no
    /// timeout of their own. Without one here, pressing "C" on a bundle
    /// whose page never yields (docs/protocol-mvp.md HTML isolation still
    /// blocks it, but a page can still hang stalling its own script thread)
    /// would leave Comment mode waiting forever on a capture that never
    /// arrives. Injectable so tests can prove the timeout path quickly.
    static let defaultCaptureTimeoutSeconds: Double = 10

    init(captureTimeoutSeconds: Double = WebViewCaptureController.defaultCaptureTimeoutSeconds) {
        self.captureTimeoutSeconds = captureTimeoutSeconds
    }

    /// Set the moment the operator does anything to the live webview - a
    /// click, a scroll, a keypress - after the session's last capture was
    /// taken. HAIL-35 contract: re-entering Comment mode with this still
    /// `false`, on the same revision, reuses the last capture instead of
    /// freezing a new one; "a new C makes a new capture" (KNOCK-11) only
    /// holds once something actually happened. Read-only from outside this
    /// file; `recordInteraction()`/`markCaptureTaken()` are its only writers.
    @Published private(set) var hasInteractedSinceLastCapture = false

    /// HAIL-75: the live page's scroll offset and viewport size, kept fresh
    /// by `trackPageViewport()` while Comment mode's layer is on screen. `nil`
    /// until the first read.
    @Published private(set) var pageViewport: PageViewport?

    /// HAIL-65: while Comment mode's region layer sits over the live view,
    /// clicks and keys land on that layer, not on the page, so they must not
    /// count as the operator changing the page. Scrolls still count: they can
    /// reach the page and move what a pin was placed on.
    var ignoresClicksAndKeys = false

    /// Comment mode can freeze a capture the instant a case opens
    /// (`KNOCK_REVIEW_MODE=comment`, Amendments) or the moment "C" is
    /// pressed, before `SandboxedHTMLView`'s webview exists or has finished
    /// its first navigation - snapshotting right away would freeze a blank
    /// page (or nothing, since `webView` may still be `nil`), leaving the
    /// "Capture n · v… · time" chip missing (Amendments: fixing a KNOCK-11
    /// defect). Retries briefly rather than giving up on the first miss.
    ///
    /// Gives up and returns whatever it has (possibly `nil`) after
    /// `maxAttempts`, rather than waiting forever for a webview that never
    /// registers (e.g. a screenshot case, which never creates one).
    ///
    /// Captures the FULL page, not just the visible viewport (HAIL-35
    /// contract: "Comment mode must scroll"): reads the document's own
    /// scroll size with a read-only JS eval (no `WKScriptMessageHandler`/
    /// `WKUserScript` added - that stays the "no bridge to the app" rule's
    /// job to forbid, untouched here), then snapshots a `WKSnapshotConfiguration`
    /// rect sized to it, capped at `fullPageCaptureHeightCap`.
    ///
    /// The retry loop above waits for more than just `!webView.isLoading`:
    /// `isLoading` can already read `false` for a moment before the real
    /// navigation has committed any layout, which would otherwise read a
    /// zero-sized `scrollHeight` and silently fall back to a tiny, unscrolled
    /// snapshot. Only a metrics read that actually comes back non-zero ends
    /// the wait.
    ///
    /// `scrollFractionBeforeCapture` (evidence-only, `KNOCK_EVIDENCE_SCROLL_FRACTION`)
    /// scrolls the page once it is confirmed ready, inside this same retry
    /// loop, rather than as a separate call racing the same load.
    func takeSnapshot(scrollFractionBeforeCapture: Double? = nil) async -> NSImage? {
        guard let result = await withTimeout(seconds: captureTimeoutSeconds, operation: { [self] in
            await performTakeSnapshot(scrollFractionBeforeCapture: scrollFractionBeforeCapture)
        }) else {
            return nil
        }
        return result
    }

    /// HAIL-65: the capture taken in the background when a comment is placed
    /// over the live prototype. Snapshots only the visible viewport - what the
    /// operator dragged the region on - and never resizes the live view, so
    /// nothing flashes. Same retry-until-loaded wait and timeout as
    /// `takeSnapshot`.
    func takeViewportSnapshot(scrollFractionBeforeCapture: Double? = nil) async -> NSImage? {
        await withTimeout(seconds: captureTimeoutSeconds, operation: { [self] in
            await performTakeViewportSnapshot(scrollFractionBeforeCapture: scrollFractionBeforeCapture)
        }) ?? nil
    }

    private func performTakeViewportSnapshot(scrollFractionBeforeCapture: Double?) async -> NSImage? {
        for attempt in 0..<Self.maxAttempts {
            if let webView, !webView.isLoading, let metrics = await readPageMetrics(from: webView), metrics.scrollHeight > 0 {
                if let scrollFractionBeforeCapture { await scrollTo(fraction: scrollFractionBeforeCapture) }
                return await snapshot(of: webView, sizeHint: nil)
            }
            if attempt < Self.maxAttempts - 1 {
                try? await Task.sleep(nanoseconds: Self.retryDelayNanoseconds)
            }
        }
        guard let webView else { return nil }
        return await snapshot(of: webView, sizeHint: nil)
    }

    private func performTakeSnapshot(scrollFractionBeforeCapture: Double?) async -> NSImage? {
        for attempt in 0..<Self.maxAttempts {
            if let webView, !webView.isLoading, let metrics = await readPageMetrics(from: webView), metrics.scrollHeight > 0 {
                if let scrollFractionBeforeCapture {
                    await scrollTo(fraction: scrollFractionBeforeCapture)
                }
                return await snapshotFullPage(
                    of: webView,
                    size: Self.captureSize(scrollWidth: metrics.scrollWidth, scrollHeight: metrics.scrollHeight)
                )
            }
            if attempt < Self.maxAttempts - 1 {
                try? await Task.sleep(nanoseconds: Self.retryDelayNanoseconds)
            }
        }
        guard let webView else { return nil }
        return await snapshot(of: webView, sizeHint: nil)
    }

    /// Grows the live webview to the full page's own size before snapshotting
    /// it, then puts it back exactly as it was.
    ///
    /// Found live (fold, HAIL-35 attempt 2): `WKWebView.takeSnapshot`'s `rect`
    /// is NOT document-relative once the view is on screen in a real window -
    /// it only ever paints what is within the view's own current bounds (its
    /// tiled compositor culls anything below the fold for performance); a
    /// `rect` taller than the view returns an image of the requested size,
    /// but everything past the view's real height comes back blank. Confirmed
    /// by dumping the raw, un-composited snapshot to disk: with the operator
    /// scrolled near the bottom of a 3-screen page, the top slice (matching
    /// the actual on-screen viewport) held real pixels and the rest was
    /// solid white. `WebViewCaptureControllerTests.
    /// takesAFullPageSnapshotTallerThanTheViewport` did not catch this
    /// because it never adds the webview to a real window - an unattached
    /// view has no "visible rect" to cull against, so it paints everything
    /// regardless, which is exactly why that test now also runs a windowed
    /// variant (`rendersRealOffscreenContentWhenAttachedToARealOnscreenWindow`).
    private func snapshotFullPage(of webView: WKWebView, size: CGSize) async -> NSImage? {
        guard size.width > 0, size.height > 0 else {
            return await snapshot(of: webView, sizeHint: nil)
        }
        let originalFrame = webView.frame
        guard size.height > originalFrame.height else {
            // Already tall enough (a page that fits the viewport) - no resize
            // needed, and resizing to a SMALLER height than today would clip.
            return await snapshot(of: webView, sizeHint: size)
        }
        // Read the live scroll offset before growing the view: once the view
        // is tall enough to show the whole document, the browser clamps
        // `scrollY` back towards 0 (there is nothing left to scroll), so this
        // is the last point this value is still meaningful. `guard let` unwraps
        // the `try?`'s own Optional first - casting straight through
        // (`(try? await ...) as? NSNumber`) silently produces `nil` every
        // time, since the intermediate type is `Any??`, not `Any?`.
        var scrollYBeforeResize: NSNumber?
        if let raw = try? await webView.evaluateJavaScript("window.scrollY") {
            scrollYBeforeResize = raw as? NSNumber
        }

        webView.frame = CGRect(origin: originalFrame.origin, size: size)
        // A frame change alone does not synchronously repaint; give WebKit a
        // beat to lay out and composite the newly-visible content before
        // snapshotting it.
        try? await Task.sleep(nanoseconds: Self.resizeSettleNanoseconds)
        let image = await snapshot(of: webView, sizeHint: size)

        webView.frame = originalFrame
        if let scrollYBeforeResize {
            _ = try? await webView.evaluateJavaScript("window.scrollTo(0, \(scrollYBeforeResize.doubleValue))")
        }
        return image
    }

    /// Where the operator was scrolled to in Interact mode, 0...1 of the
    /// full page, so Comment mode's stage can open at the same spot
    /// (HAIL-35 contract). `0` (top) without a registered webview or a
    /// scrollable page.
    func currentScrollFraction() async -> Double {
        guard let webView, let metrics = await readPageMetrics(from: webView) else { return 0 }
        return Self.scrollFraction(scrollY: metrics.scrollY, scrollHeight: metrics.scrollHeight, viewportHeight: metrics.viewportHeight)
    }

    /// Evidence-only (`takeSnapshot(scrollFractionBeforeCapture:)`, driven by
    /// `KNOCK_EVIDENCE_SCROLL_FRACTION` in `ReviewViewModel`): scrolls the
    /// live page right before a capture, so the evidence harness - no
    /// accessibility permission for a real scroll gesture - can still
    /// exercise the actual "capture reads the operator's own scroll
    /// position" path end to end, instead of faking the resulting
    /// `scrollFraction` after the fact.
    private func scrollTo(fraction: Double) async {
        guard let webView else { return }
        _ = try? await webView.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight * \(fraction))")
    }

    /// Evidence only (`KNOCK_EVIDENCE_WINDOW_SHOT`): writes this app's own
    /// window to a PNG without any screen-recording permission. The window's
    /// AppKit/SwiftUI layers render through `cacheDisplay` (which leaves a
    /// `WKWebView` as an opaque dark box); the web view's pixels come from
    /// `takeSnapshot` and are drawn over it. Returns false without a window.
    func writeWindowShot(to path: String) async -> Bool {
        guard let webView, let window = webView.window, let content = window.contentView else { return false }
        // The first snapshot after a resize can come back blank; take a second after a pause.
        _ = await snapshot(of: webView, sizeHint: nil)
        try? await Task.sleep(nanoseconds: 800_000_000)
        let pageShot = await snapshot(of: webView, sizeHint: nil)
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return false }
        content.cacheDisplay(in: content.bounds, to: rep)
        let pages = pageShot.map { [($0, content.convert(webView.bounds, from: webView))] } ?? []
        guard let png = EvidenceComposite.png(content: content, cached: rep, pages: pages) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// Evidence only (HAIL-141c): runs read-only JS and returns its result as text.
    func evaluate(_ script: String) async -> String? {
        guard let webView, let raw = try? await webView.evaluateJavaScript(script) else { return nil }
        return "\(raw)"
    }

    /// Evidence only: the web view's width in points.
    var webViewWidth: CGFloat { webView?.bounds.width ?? 0 }

    /// Evidence only: the web view's size in points (the comment layer's size).
    var evidenceLayerSize: CGSize { webView?.bounds.size ?? .zero }

    /// Evidence only: the CoreGraphics id of the window holding the page.
    var evidenceWindowNumber: Int { webView?.window?.windowNumber ?? 0 }

    /// Evidence only (Comment mode zoom): what a scroll at the page centre
    /// hits (the pan monitor forwards it when that is the host drawing the
    /// comment layer), and whether a 240 px scroll handed to the page the way
    /// the monitor hands it moves the page. Nothing is posted to the system.
    func evidenceScrollProbe() async -> String {
        guard let webView, let window = webView.window else { return "no window" }
        let centre = webView.convert(CGPoint(x: webView.bounds.midX, y: webView.bounds.midY), to: nil)
        let hit = window.contentView?.hitTest(centre)
        let forwards = PrototypePanMonitor.shouldForwardScroll(hit: hit, webView: webView)
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -240, wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: cg) else { return "no event" }
        let before = await readPageViewport()?.scrollY ?? -1
        webView.scrollWheel(with: event)
        try? await Task.sleep(nanoseconds: 600_000_000)
        let after = await readPageViewport()?.scrollY ?? -1
        let kind = hit.map { String(describing: type(of: $0)).prefix(24) } ?? "nil"
        return "hit=\(kind) forwards=\(forwards) scrollY \(before) -> \(after)"
    }

    /// Evidence only (HAIL-131): writes just the web view's own pixels to a PNG.
    func writeWebShot(to path: String) async -> Bool {
        guard let webView else { return false }
        _ = await snapshot(of: webView, sizeHint: nil)
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard let image = await snapshot(of: webView, sizeHint: nil), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// Reads the page's scroll offset and viewport size once (read-only JS,
    /// same rule as `readPageMetrics`: the app asks, the page never calls back).
    /// The zoom is read before the script is sent: the web process handles the
    /// zoom change first, so the CSS px values are at that zoom.
    func readPageViewport() async -> PageViewport? {
        guard let webView, !webView.isLoading else { return nil }
        let zoom = Double(webView.pageZoom)
        guard let raw = try? await webView.evaluateJavaScript(PageViewport.readScript), let values = raw as? [NSNumber] else { return nil }
        return PageViewport.make(values: values.map(\.doubleValue), zoom: zoom, viewSize: webView.bounds.size)
    }

    /// Polls `readPageViewport` until the calling task is cancelled, so pins
    /// follow the page while it scrolls (HAIL-75). A poll, not a script
    /// bridge: the isolation rules forbid the page messaging the app. Run
    /// from a `.task` on the layer, so it only runs while pins are on screen.
    func trackPageViewport() async {
        while !Task.isCancelled {
            if let viewport = await readPageViewport(), viewport != pageViewport { pageViewport = viewport }
            try? await Task.sleep(nanoseconds: Self.viewportPollNanoseconds)
        }
    }

    /// HAIL-240: the element under a pin (`fx`, `fy` are 0...1 of the page frame). Read-only JS in the
    /// app's own content world, so a page that rewrites `JSON` or the DOM prototypes cannot change the
    /// script. The answer is parsed, capped and sanitised by `PageElementContext.parse`.
    func readElement(atX fx: Double, y fy: Double) async -> PageElementContext? {
        await readElement(script: PageElementContext.readScript(fx: fx, fy: fy))
    }

    /// WAG-280: the element at a point in page coordinates (CSS px from the top left of the document),
    /// for a pin placed on a capture of the page. `nil` when the page is no longer there to ask.
    func readElement(pageX: Double, pageY: Double) async -> PageElementContext? {
        await readElement(script: PageElementContext.readScript(pageX: pageX, pageY: pageY))
    }

    private func readElement(script: String) async -> PageElementContext? {
        guard let webView else { return nil }
        // Bounded: a page that hangs its script thread must not hold Send waiting for its element.
        let context = await withTimeout(seconds: 3, operation: { @MainActor () -> PageElementContext? in
            // A page still loading its images has its layout already: ask at once, and once more
            // shortly after if the first ask found nothing (WAG-280: a loading flag held the read
            // back for pages whose last image never settled).
            for attempt in 0..<2 {
                let raw = try? await webView.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)
                if let parsed = PageElementContext.parse(raw ?? nil) { return parsed }
                if attempt == 0, webView.isLoading { try? await Task.sleep(nanoseconds: 400_000_000) } else { break }
            }
            return nil
        })
        return context ?? nil
    }

    /// HAIL-103: the view the live page is on now (hash and fingerprint of its
    /// visible text), kept fresh by `trackPageView()`. `nil` until the first read.
    @Published private(set) var pageView: PageView?

    /// Reads the page's `location.hash` and visible text once. Read-only JS, like
    /// `readPageViewport`: the page cannot call back, so the isolation rules hold.
    func readPageView() async -> PageView? {
        guard let webView, !webView.isLoading else { return nil }
        let script = "[location.hash, (document.body ? document.body.innerText : '').slice(0, \(PageView.textCap * 4))]"
        guard let raw = try? await webView.evaluateJavaScript(script), let values = raw as? [String], values.count == 2 else { return nil }
        return PageView.make(hash: values[0], text: values[1])
    }

    /// Polls `readPageView` until cancelled: a cheap throttled check (twice a
    /// second) that catches `hashchange`, tab switches and DOM changes alike,
    /// with no script bridge.
    func trackPageView() async {
        while !Task.isCancelled {
            if let view = await readPageView(), view != pageView { pageView = view }
            try? await Task.sleep(nanoseconds: Self.viewPollNanoseconds)
        }
    }

    /// Jumps the live page to a view address (the app sets the hash; the page
    /// renders from `hashchange`). Refreshes `pageView` after a beat.
    func setHash(_ hash: String) async {
        guard let webView, let literal = try? JSONSerialization.data(withJSONObject: [hash]), let json = String(data: literal, encoding: .utf8) else { return }
        _ = try? await webView.evaluateJavaScript("location.hash = \(json)[0]")
        try? await Task.sleep(nanoseconds: 80_000_000)
        if let view = await readPageView() { pageView = view }
    }

    /// Scrolls the live page so a pin is in view (HAIL-75). Updates
    /// `pageViewport` at once so the pins do not lag a poll behind.
    func scrollPage(to offset: CGPoint) async {
        guard let webView else { return }
        _ = try? await webView.evaluateJavaScript("window.scrollTo(\(offset.x), \(offset.y))")
        if let viewport = await readPageViewport() { pageViewport = viewport }
    }

    private func snapshot(of webView: WKWebView, sizeHint: CGSize?) async -> NSImage? {
        var configuration: WKSnapshotConfiguration?
        if let sizeHint, sizeHint.width > 0, sizeHint.height > 0 {
            let rectConfiguration = WKSnapshotConfiguration()
            rectConfiguration.rect = CGRect(origin: .zero, size: sizeHint)
            configuration = rectConfiguration
        }
        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private struct PageMetrics {
        let scrollWidth: CGFloat
        let scrollHeight: CGFloat
        let scrollY: CGFloat
        let viewportHeight: CGFloat
    }

    /// Read-only DOM sizing/scroll read, not a bridge: nothing here lets the
    /// page call back into the app, it only lets the app ask the page a
    /// question (docs/protocol-mvp.md HTML isolation is about the reverse
    /// direction).
    private func readPageMetrics(from webView: WKWebView) async -> PageMetrics? {
        let script = """
        ({
          scrollWidth: document.documentElement.scrollWidth,
          scrollHeight: Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0),
          scrollY: window.scrollY,
          viewportHeight: window.innerHeight
        })
        """
        guard let raw = try? await webView.evaluateJavaScript(script), let result = raw as? [String: Any] else { return nil }
        guard let scrollWidth = (result["scrollWidth"] as? NSNumber)?.doubleValue,
              let scrollHeight = (result["scrollHeight"] as? NSNumber)?.doubleValue,
              let scrollY = (result["scrollY"] as? NSNumber)?.doubleValue,
              let viewportHeight = (result["viewportHeight"] as? NSNumber)?.doubleValue else { return nil }
        return PageMetrics(scrollWidth: scrollWidth, scrollHeight: scrollHeight, scrollY: scrollY, viewportHeight: viewportHeight)
    }

    /// Marks the interaction flag consumed once a capture is actually taken
    /// - called by `ReviewViewModel.takeCapture()`, never from inside this
    /// file's own snapshot path, since a reused capture (no new snapshot)
    /// must not reset it either.
    func markCaptureTaken() {
        hasInteractedSinceLastCapture = false
    }

    private static let viewPollNanoseconds: UInt64 = 500_000_000
    private static let viewportPollNanoseconds: UInt64 = 40_000_000
    private static let maxAttempts = 10
    private static let retryDelayNanoseconds: UInt64 = 50_000_000
    private static let resizeSettleNanoseconds: UInt64 = 80_000_000
}

extension WebViewCaptureController {
    /// `SandboxedHTMLView`'s registration point; a separate method (rather
    /// than exposing the `webView` property) keeps the "only this file
    /// touches the webview" rule enforceable by inspection.
    func register(_ webView: WKWebView) {
        self.webView = webView
        installInteractionMonitor()
    }

    /// Cap on the full-page capture's height (HAIL-35 contract: "Cap very
    /// tall pages at a sensible height"). Choice: 12000pt, recorded in the
    /// report's Choices ledger - a page with no natural end (infinite
    /// scroll, a pathologically tall prototype) would otherwise attempt an
    /// unbounded snapshot and an unusable mile-long Comment-mode scroll.
    static let fullPageCaptureHeightCap: CGFloat = 12000

    /// Pure sizing for the full-page snapshot rect - unit-tested without any
    /// live `WKWebView` (`WebViewCaptureControllerTests`).
    static func captureSize(scrollWidth: CGFloat, scrollHeight: CGFloat, cap: CGFloat = fullPageCaptureHeightCap) -> CGSize {
        CGSize(width: max(scrollWidth, 0), height: min(max(scrollHeight, 0), max(cap, 0)))
    }

    /// Pure scroll-position math shared by `currentScrollFraction()` -
    /// unit-tested directly.
    static func scrollFraction(scrollY: CGFloat, scrollHeight: CGFloat, viewportHeight: CGFloat) -> Double {
        let scrollable = max(scrollHeight - viewportHeight, 0)
        guard scrollable > 0 else { return 0 }
        return Double(min(max(scrollY / scrollable, 0), 1))
    }

    /// Test/production seam for the "did the operator touch the artifact"
    /// signal: the real monitor below calls this; a test can call it
    /// directly without any real `NSEvent`/`WKWebView` plumbing.
    func recordInteraction() {
        hasInteractedSinceLastCapture = true
    }

    /// Native AppKit event observation, not a WebKit bridge: watches clicks/
    /// scrolls/keypresses landing on the registered webview's own bounds (or
    /// its first responder, for a keypress) while its window is key. Reinstalled
    /// on every `register()` - a fresh `WKWebView` is created each time
    /// `SandboxedHTMLView` re-enters Interact mode (Comment mode swaps it out
    /// of the view tree entirely), so the monitor must repoint at the new one.
    private func installInteractionMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            self?.handlePotentialInteraction(event)
            return event
        }
    }

    private func handlePotentialInteraction(_ event: NSEvent) {
        guard let webView, let window = webView.window, event.window === window else { return }
        switch event.type {
        case .keyDown where ignoresClicksAndKeys, .leftMouseDown where ignoresClicksAndKeys, .rightMouseDown where ignoresClicksAndKeys:
            break
        case .keyDown:
            if let responder = window.firstResponder as? NSView, responder === webView || responder.isDescendant(of: webView) {
                recordInteraction()
            }
        case .leftMouseDown, .rightMouseDown, .scrollWheel:
            let location = webView.convert(event.locationInWindow, from: nil)
            if webView.bounds.contains(location) {
                recordInteraction()
            }
        default:
            break
        }
    }
}
