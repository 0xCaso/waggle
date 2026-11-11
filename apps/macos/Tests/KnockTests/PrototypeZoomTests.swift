import Testing
import AppKit
import WebKit
@testable import Knock

/// HAIL-127: the prototype's zoom state model and the Comment mode rule.
@MainActor
struct PrototypeZoomTests {
    @Test func startsAtOneHundredPercent() {
        let zoom = PrototypeZoomModel()
        #expect(zoom.storedScale == 1)
        #expect(zoom.percentText == "100%")
        #expect(zoom.isActualSize)
    }

    @Test func clampsBetweenTwentyFiveAndFourHundredPercent() {
        let zoom = PrototypeZoomModel()
        zoom.setScale(50)
        #expect(zoom.storedScale == 4)
        zoom.setScale(0.01)
        #expect(zoom.storedScale == 0.25)
        zoom.pinch(by: 0.05, anchor: .zero)
        #expect(zoom.storedScale == 0.25, "a pinch cannot go below the floor")
        #expect(PrototypeZoomModel.clamp(.nan) == 1)
    }

    @Test func pinchScalesFromTheCurrentZoomAndKeepsTheAnchor() {
        let zoom = PrototypeZoomModel()
        zoom.pinch(by: 1.5, anchor: CGPoint(x: 10, y: 20))
        #expect(abs(zoom.storedScale - 1.5) < 0.0001)
        #expect(zoom.percentText == "150%")
        #expect(zoom.takePendingAnchor() == CGPoint(x: 10, y: 20))
        #expect(zoom.takePendingAnchor() == nil, "the anchor is read once")
    }

    @Test func smartZoomTogglesBetweenOneHundredAndTwoHundredPercent() {
        let zoom = PrototypeZoomModel()
        zoom.smartZoom(anchor: .zero)
        #expect(zoom.storedScale == 2)
        zoom.smartZoom(anchor: .zero)
        #expect(zoom.storedScale == 1)
        zoom.setScale(3)
        zoom.smartZoom(anchor: .zero)
        #expect(zoom.storedScale == 1, "anything but 100% goes back to 100%")
    }

    @Test func fitAndStepsLandOnOneHundredPercentExactly() {
        let zoom = PrototypeZoomModel()
        zoom.zoomIn()
        #expect(zoom.storedScale == 1.25)
        zoom.zoomOut()
        #expect(zoom.storedScale == 1)
        zoom.setScale(2)
        zoom.fit()
        #expect(zoom.storedScale == 1)
    }

    @Test func resetReturnsToOneHundredPercent() {
        let zoom = PrototypeZoomModel()
        zoom.setScale(2, anchor: CGPoint(x: 1, y: 1))
        zoom.reset()
        #expect(zoom.storedScale == 1)
        #expect(zoom.takePendingAnchor() == nil)
    }

    /// Operator, 4 Oct: Interact shows its pins at every zoom, like Comment mode.
    /// The layer choice depends on the mode only, never on the zoom.
    @Test func pinsAreShownInBothModesAtEveryZoom() async {
        let viewModel = ReviewViewModel(client: KnockClient(socketPath: "/tmp/knock-none.sock", backoffSchedule: [0.02]))
        for scale in [0.5, 1, 2] as [CGFloat] {
            viewModel.prototypeZoom.setScale(scale)
            #expect(LiveStageLayer.make(mode: viewModel.mode, showsStillOverLive: viewModel.showsStillOverLive) == .pins, "Interact at \(scale)")
        }
        await viewModel.enterCommentMode()
        #expect(LiveStageLayer.make(mode: viewModel.mode, showsStillOverLive: viewModel.showsStillOverLive) == .commentLayer)
        #expect(LiveStageLayer.make(mode: .comment, showsStillOverLive: true) == .still)
    }

    /// Operator, 4 Oct: Comment mode keeps the zoom and still zooms.
    @Test func commentModeKeepsTheZoomAndStillZooms() async {
        let viewModel = ReviewViewModel(client: KnockClient(socketPath: "/tmp/knock-none.sock", backoffSchedule: [0.02]))
        viewModel.prototypeZoom.setScale(2)
        await viewModel.enterCommentMode()
        #expect(viewModel.mode == .comment)
        #expect(viewModel.prototypeZoom.storedScale == 2, "the page stays at the zoom the person chose")
        viewModel.prototypeZoom.zoomIn()
        #expect(viewModel.prototypeZoom.storedScale == 2.5)
        viewModel.prototypeZoom.pinch(by: 0.5, anchor: .zero)
        #expect(viewModel.prototypeZoom.storedScale == 1.25)
        viewModel.prototypeZoom.actualSize()
        #expect(viewModel.prototypeZoom.storedScale == 1, "Actual Size still gives 100%")
    }

    /// HAIL-143: the web view takes the model's scale through `pageZoom`, which re-lays the page out.
    @Test func webViewAppliesPageZoomProgrammatically() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = webView
        webView.pageZoom = 0.42
        #expect(abs(webView.pageZoom - 0.42) < 0.0001)
        webView.pageZoom = 1
        #expect(abs(webView.pageZoom - 1) < 0.0001)
    }
}

/// HAIL-131: the canvas maths.
struct PrototypeCanvasTests {
    @Test func zoomKeepsThePointUnderThePointerFixed() {
        let pointer = CGPoint(x: 600, y: 400)
        let scroll = CGPoint(x: 30, y: 120)
        let origin = PrototypeCanvas.scrollOrigin(keeping: pointer, scroll: scroll, from: 1, to: 2)
        // The page point under the pointer, before and after.
        let before = CGPoint(x: scroll.x + pointer.x / 1, y: scroll.y + pointer.y / 1)
        let after = CGPoint(x: origin.x + pointer.x / 2, y: origin.y + pointer.y / 2)
        #expect(abs(before.x - after.x) < 0.0001 && abs(before.y - after.y) < 0.0001)
        #expect(origin == CGPoint(x: 330, y: 320))
    }

    @Test func zoomOutIsTheInverseOfZoomIn() {
        let pointer = CGPoint(x: 250, y: 90)
        let scroll = CGPoint(x: 10, y: 20)
        let zoomed = PrototypeCanvas.scrollOrigin(keeping: pointer, scroll: scroll, from: 1, to: 2.5)
        let back = PrototypeCanvas.scrollOrigin(keeping: pointer, scroll: zoomed, from: 2.5, to: 1)
        #expect(abs(back.x - scroll.x) < 0.0001 && abs(back.y - scroll.y) < 0.0001)
    }

    @Test func scrollStaysInsideThePage() {
        let page = CGSize(width: 1000, height: 3000)
        let viewport = CGSize(width: 800, height: 600)
        #expect(PrototypeCanvas.clamped(scroll: CGPoint(x: -50, y: -5), page: page, viewport: viewport, scale: 2) == .zero)
        // At 2x the viewport shows 400 x 300 CSS px.
        #expect(PrototypeCanvas.clamped(scroll: CGPoint(x: 9000, y: 9000), page: page, viewport: viewport, scale: 2) == CGPoint(x: 600, y: 2700))
        // A page smaller than the viewport does not scroll.
        #expect(PrototypeCanvas.clamped(scroll: CGPoint(x: 40, y: 40), page: CGSize(width: 300, height: 200), viewport: viewport, scale: 1) == .zero)
    }

    @Test func fitFramesThePageWidth() {
        #expect(PrototypeCanvas.fitScale(viewportWidth: 800, pageWidth: 1600, minimum: 0.25, maximum: 4) == 0.5)
        #expect(PrototypeCanvas.fitScale(viewportWidth: 800, pageWidth: 600, minimum: 0.25, maximum: 4) == 1)
        #expect(PrototypeCanvas.fitScale(viewportWidth: 800, pageWidth: 8000, minimum: 0.25, maximum: 4) == 0.25)
        #expect(PrototypeCanvas.fitScale(viewportWidth: 0, pageWidth: 100, minimum: 0.25, maximum: 4) == 1)
    }

    @Test func diagramFitGrowsAndShrinksToTheViewerWidth() {
        // A narrow diagram grows to fill the width; a wide one shrinks to it.
        #expect(abs(PrototypeCanvas.fitScaleUpscaling(viewportWidth: 800, pageWidth: 520, minimum: 0.25, maximum: 4) - 800.0 / 520.0) < 1e-9)
        #expect(PrototypeCanvas.fitScaleUpscaling(viewportWidth: 800, pageWidth: 1600, minimum: 0.25, maximum: 4) == 0.5)
        #expect(PrototypeCanvas.fitScaleUpscaling(viewportWidth: 800, pageWidth: 8000, minimum: 0.25, maximum: 4) == 0.25)
        #expect(PrototypeCanvas.fitScaleUpscaling(viewportWidth: 800, pageWidth: 40, minimum: 0.25, maximum: 4) == 4)
        #expect(PrototypeCanvas.fitScaleUpscaling(viewportWidth: 0, pageWidth: 100, minimum: 0.25, maximum: 4) == 1)
    }

    @MainActor @Test func fitUsesThePageWidthReader() async {
        let zoom = PrototypeZoomModel()
        zoom.pageWidthReader = { (page: 2000, viewport: 1000) }
        zoom.fit()
        _ = try? await pollUntil(.seconds(20)) { zoom.storedScale == 0.5 }
        #expect(zoom.storedScale == 0.5)
        zoom.actualSize()
        #expect(zoom.storedScale == 1)
    }

    @MainActor @Test func diagramFitUpscalesANarrowPage() async {
        let zoom = PrototypeZoomModel()
        zoom.fitUpscales = true
        zoom.pageWidthReader = { (page: 520, viewport: 800) }
        zoom.fit()
        _ = try? await pollUntil(.seconds(20)) { abs(zoom.storedScale - 800.0 / 520.0) < 0.0001 }
        #expect(abs(zoom.storedScale - 800.0 / 520.0) < 0.0001)
    }

    @MainActor @Test func prototypeFitNeverUpscales() async {
        let zoom = PrototypeZoomModel()
        zoom.pageWidthReader = { (page: 520, viewport: 800) }
        zoom.fit()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(zoom.storedScale == 1)
    }
}

@MainActor
struct PrototypeSpaceDecisionTests {
    private func take(_ focus: PrototypePanMonitor.Focus, inside: Bool = true, editable: Bool = false) -> Bool {
        PrototypePanMonitor.shouldTakeSpace(pointerInside: inside, focus: focus, pageEditableFocused: editable)
    }

    @Test func textFieldFocusedOverPageIsNotTaken() { #expect(!take(.textInput)) }
    @Test func webViewFocusedOverPageIsTaken() { #expect(take(.page)) }
    @Test func pageInputFocusedIsNotTaken() { #expect(!take(.page, editable: true)) }
    @Test func pointerOutsideIsNotTaken() { #expect(!take(.page, inside: false)); #expect(!take(.other, inside: false)) }
    @Test func nothingTakingTextStillPans() { #expect(take(.other)) }

    /// Comment mode (operator, 4 Oct): a scroll on the layer over the page
    /// (drawn by the host that holds the web view) goes to the page; a scroll
    /// on the page or on a native view of its own stays where it landed.
    @Test func scrollOnTheCommentLayerGoesToThePage() {
        let host = NSView()
        let container = NSView()
        let web = NSView()
        let inPage = NSView()
        let field = NSTextField()
        host.addSubview(container)
        container.addSubview(web)
        web.addSubview(inPage)
        host.addSubview(field)
        #expect(PrototypePanMonitor.shouldForwardScroll(hit: host, webView: web))
        #expect(PrototypePanMonitor.shouldForwardScroll(hit: container, webView: web))
        #expect(!PrototypePanMonitor.shouldForwardScroll(hit: web, webView: web))
        #expect(!PrototypePanMonitor.shouldForwardScroll(hit: inPage, webView: web))
        #expect(!PrototypePanMonitor.shouldForwardScroll(hit: field, webView: web))
        #expect(!PrototypePanMonitor.shouldForwardScroll(hit: nil, webView: web))
    }

    @Test func classifiesResponders() {
        let web = NSView()
        let child = NSView()
        web.addSubview(child)
        let field = NSTextField()
        let textView = NSTextView()
        #expect(PrototypePanMonitor.focus(of: nil, webView: web) == .other)
        #expect(PrototypePanMonitor.focus(of: web, webView: web) == .page)
        #expect(PrototypePanMonitor.focus(of: child, webView: web) == .page)
        #expect(PrototypePanMonitor.focus(of: field, webView: web) == .textInput)
        #expect(PrototypePanMonitor.focus(of: textView, webView: web) == .textInput)
        #expect(PrototypePanMonitor.focus(of: NSView(), webView: web) == .other)
    }
}
