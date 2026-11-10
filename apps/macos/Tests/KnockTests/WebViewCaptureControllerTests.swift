import Testing
import AppKit
import WebKit
@testable import Knock

/// Amendments (fixing a KNOCK-11 defect): Comment mode entered before a
/// staged `html_bundle`'s webview has finished loading must still take a
/// capture, not silently take none.
@MainActor
struct WebViewCaptureControllerTests {
    @Test func returnsNilWithNoWebViewRegistered() async {
        let controller = WebViewCaptureController()
        let image = await controller.takeSnapshot()
        #expect(image == nil)
    }

    /// HAIL-55 contract: "the review canvas stays responsive... no main-
    /// thread stalls from... snapshotting." `readPageMetrics`'s
    /// `evaluateJavaScript` has no timeout of its own - a page whose script
    /// thread never yields (docs/protocol-mvp.md isolation still blocks
    /// network access, but a page can still hang its own script) would
    /// otherwise leave Comment mode's "C" waiting forever on a capture that
    /// never arrives. A short injected bound keeps the test fast.
    @Test func takeSnapshotReturnsNilRatherThanHangingWhenThePagesScriptNeverYields() async {
        let controller = WebViewCaptureController(captureTimeoutSeconds: 0.5)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        controller.register(webView)
        webView.loadHTMLString(
            "<body style='margin:0'><script>var s=Date.now();while(Date.now()-s<60000){}</script></body>",
            baseURL: nil
        )

        let start = Date()
        let image = await controller.takeSnapshot()

        #expect(image == nil)
        #expect(Date().timeIntervalSince(start) < 20, "must settle at the injected bound, not wait out the page's own 60s busy-loop")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil, "needs a drawn window; not on CI runners")) func takesASnapshotEvenWhenCalledBeforeNavigationFinishes() async {
        let controller = WebViewCaptureController()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        controller.register(webView)
        webView.loadHTMLString("<body style='background:white'>hello</body>", baseURL: nil)

        // No wait here: `takeSnapshot` itself must retry until the page has
        // actually finished loading, per the fix (`isLoading` gate + a
        // bounded poll), rather than snapshotting a blank/mid-navigation
        // page or returning nothing at all.
        let image = await controller.takeSnapshot()

        #expect(image != nil, "should retry until the webview finishes loading rather than taking no capture")
    }

    /// HAIL-35 contract: Comment mode must capture the FULL page, taller
    /// than the viewport, reading the document's own scroll size with JS.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil, "needs a drawn window; not on CI runners")) func takesAFullPageSnapshotTallerThanTheViewport() async {
        let controller = WebViewCaptureController()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        controller.register(webView)
        webView.loadHTMLString(
            "<body style='margin:0;background:white;width:200px;height:900px'>tall page</body>",
            baseURL: nil
        )

        let image = await controller.takeSnapshot()

        let height = try? #require(image?.size.height)
        #expect((height ?? 0) > 100, "the capture should cover the page's full scroll height (900px), not just the 100pt viewport")
    }

    /// HAIL-35 fold (attempt 2): live-app evidence found pins missing from a
    /// full-page capture. Root cause, confirmed by dumping the raw snapshot
    /// to disk from the real app: `WKWebView.takeSnapshot`'s `rect` is NOT
    /// document-relative once the view is on screen in a real window - it
    /// only ever paints what is within the view's own current bounds, so a
    /// `rect` taller than the view came back the RIGHT size but with
    /// everything below the actual on-screen viewport left blank.
    ///
    /// `takesAFullPageSnapshotTallerThanTheViewport` above did not catch this
    /// because its `WKWebView` is never added to a window - an unattached
    /// view has no "visible rect" to cull against, so it happens to paint
    /// everything regardless of the real bug. This test attaches the webview
    /// to a real, on-screen `NSWindow` (the same condition the live app
    /// hits) and checks actual pixel content near the bottom of the capture,
    /// not just its reported size - a capture that pads the missing region
    /// blank instead of cropping it would still pass a size-only assertion.
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil, "needs a drawn window; not on CI runners")) func rendersRealOffscreenContentWhenAttachedToARealOnscreenWindow() async throws {
        let controller = WebViewCaptureController()
        let viewportHeight: CGFloat = 100
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: viewportHeight),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: viewportHeight))
        window.contentView = webView
        window.orderFrontRegardless()
        controller.register(webView)
        defer { window.orderOut(nil) }

        // A page far taller than the 100pt viewport, with a solid red strip
        // only in its last 100px - real content the capture can only contain
        // if it genuinely rendered content below the visible fold, not a
        // blank pad the right size.
        webView.loadHTMLString(
            "<body style='margin:0'><div style='height:400px;background:white'></div>"
                + "<div style='height:100px;background:rgb(255,0,0)'></div></body>",
            baseURL: nil
        )

        let image = try #require(await controller.takeSnapshot())
        #expect(image.size.height > 400, "the capture should cover the full 500px page, not the 100pt viewport")

        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        // Sample across the capture's height rather than assuming which
        // direction is "down" in bitmap-row space - what matters is that the
        // red strip shows up as real pixels SOMEWHERE, not padding blank.
        let foundRed = stride(from: 0.05, through: 0.95, by: 0.1).contains { fraction in
            let y = min(bitmap.pixelsHigh - 1, Int(Double(bitmap.pixelsHigh) * fraction))
            let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: y)
            return (color?.redComponent ?? 0) > 0.5 && (color?.greenComponent ?? 1) < 0.5
        }
        #expect(foundRed, "the capture must contain the page's real off-screen content (the red strip), not blank space past the on-screen viewport")
    }
}

/// `WebViewCaptureController.captureSize`: the full-page snapshot's pure
/// sizing math (HAIL-35 contract test list: "full-page capture sizing logic
/// (pure function)"), unit-tested without any live `WKWebView`.
@MainActor
struct WebViewCaptureControllerCaptureSizeTests {
    @Test func usesThePagesOwnScrollSizeWhenUnderTheCap() {
        let size = WebViewCaptureController.captureSize(scrollWidth: 1200, scrollHeight: 3000, cap: 12000)
        #expect(size.width == 1200)
        #expect(size.height == 3000)
    }

    @Test func capsAPageTallerThanTheCap() {
        let size = WebViewCaptureController.captureSize(scrollWidth: 1200, scrollHeight: 20000, cap: 12000)
        #expect(size.height == 12000, "a page with no natural end must not produce an unbounded snapshot")
        #expect(size.width == 1200)
    }

    @Test func neverProducesANegativeSize() {
        let size = WebViewCaptureController.captureSize(scrollWidth: -1, scrollHeight: -1, cap: 12000)
        #expect(size.width == 0)
        #expect(size.height == 0)
    }

    @Test func defaultCapIsTwelveThousandPoints() {
        let size = WebViewCaptureController.captureSize(scrollWidth: 100, scrollHeight: 50000)
        #expect(size.height == 12000)
    }
}

/// `WebViewCaptureController.scrollFraction`: the pure math behind "first
/// scrolled to where the operator was in Interact mode."
@MainActor
struct WebViewCaptureControllerScrollFractionTests {
    @Test func halfwayScrolledPageReturnsOneHalf() {
        let fraction = WebViewCaptureController.scrollFraction(scrollY: 450, scrollHeight: 1000, viewportHeight: 100)
        #expect(fraction == 0.5)
    }

    @Test func aPageShorterThanTheViewportIsNotScrollable() {
        let fraction = WebViewCaptureController.scrollFraction(scrollY: 0, scrollHeight: 50, viewportHeight: 100)
        #expect(fraction == 0)
    }

    @Test func clampsToOneAtTheBottomOfThePage() {
        let fraction = WebViewCaptureController.scrollFraction(scrollY: 5000, scrollHeight: 1000, viewportHeight: 100)
        #expect(fraction == 1)
    }
}

/// `WebViewCaptureController.hasInteractedSinceLastCapture`: the reuse-last-
/// capture signal (HAIL-35 contract: "the operator did not interact since
/// the last capture"), exercised through `recordInteraction()`/
/// `markCaptureTaken()` rather than real `NSEvent`s.
@MainActor
struct WebViewCaptureControllerInteractionTests {
    @Test func startsFalseAndFlipsTrueOnceAnInteractionIsRecorded() {
        let controller = WebViewCaptureController()
        #expect(controller.hasInteractedSinceLastCapture == false)

        controller.recordInteraction()

        #expect(controller.hasInteractedSinceLastCapture)
    }

    @Test func markingACaptureTakenResetsTheFlag() {
        let controller = WebViewCaptureController()
        controller.recordInteraction()
        #expect(controller.hasInteractedSinceLastCapture)

        controller.markCaptureTaken()

        #expect(controller.hasInteractedSinceLastCapture == false)
    }
}
