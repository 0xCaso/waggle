import Testing
import AppKit
import WebKit
@testable import Knock

/// WAG-280: the element under a pin, on a page shaped like an "Investor demo" bundle: a header,
/// rows of phone frames that scroll sideways, images and headings, and a nested scroller.
@MainActor
struct PageElementPickTests {
    static let fixture = """
    <!doctype html><body style="margin:0;font:14px sans-serif">
    <header id="top" style="height:80px;background:#eee"><h1>Investor demo</h1></header>
    <section><h2>Onboarding</h2>
    <div id="row1" style="display:flex;gap:16px;overflow-x:auto;width:100%">
    \((1...6).map { "<figure style=\"flex:none;width:300px;margin:0\"><img alt=\"Onboarding screen \($0)\" style=\"display:block;width:300px;height:200px;background:#cde\"><figcaption><h3>Screen \($0)</h3></figcaption></figure>" }.joined())
    </div></section>
    <section><h2>Checkout</h2>
    <div id="outer" style="height:240px;overflow-y:auto;width:420px;border:1px solid #ccc">
    <div style="height:600px"><div id="inner" style="margin-top:300px;height:60px"><button style="width:200px;height:50px">Pay now</button></div></div></div>
    </section>
    <div style="height:1400px"></div></body>
    """

    private func makeController(size: CGSize = CGSize(width: 900, height: 600)) async throws -> (WebViewCaptureController, WKWebView, NSWindow) {
        let controller = WebViewCaptureController()
        let webView = WKWebView(frame: NSRect(origin: .zero, size: size))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = webView
        controller.register(webView)
        webView.loadHTMLString(Self.fixture, baseURL: nil)
        let deadline = Date().addingTimeInterval(20)
        while webView.isLoading && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        try await Task.sleep(nanoseconds: 300_000_000)
        return (controller, webView, window)
    }

    /// The centre of `selector` as a 0...1 fraction of the view, read from the page itself.
    private func fraction(of selector: String, in webView: WKWebView) async throws -> (Double, Double) {
        let raw = try await webView.evaluateJavaScript("(function(){var r=document.querySelector('\(selector)').getBoundingClientRect();return [(r.left+r.width/2)/window.innerWidth,(r.top+r.height/2)/window.innerHeight];})()")
        let values = try #require(raw as? [NSNumber])
        return (values[0].doubleValue, values[1].doubleValue)
    }

    private func settle(_ webView: WKWebView) async throws { try await Task.sleep(nanoseconds: 250_000_000); _ = try? await webView.evaluateJavaScript("1") }

    @Test func picksAHeadingAt100Percent() async throws {
        let (controller, webView, window) = try await makeController()
        _ = window
        let (x, y) = try await fraction(of: "h1", in: webView)
        let context = try #require(await controller.readElement(atX: x, y: y))
        #expect(context.role == "heading")
        #expect(context.text == "Investor demo")
    }

    @Test func picksAnImageAtFitScale() async throws {
        let (controller, webView, window) = try await makeController()
        _ = window
        webView.pageZoom = 0.5
        try await settle(webView)
        let (x, y) = try await fraction(of: "#row1 figure:nth-child(2) img", in: webView)
        let context = try #require(await controller.readElement(atX: x, y: y))
        #expect(context.role == "image")
        #expect(context.text == "Onboarding screen 2")
        #expect(context.heading == "Screen 2")
    }

    @Test func picksAFrameAfterTheRowScrolledSideways() async throws {
        let (controller, webView, window) = try await makeController()
        _ = window
        _ = try await webView.evaluateJavaScript("document.getElementById('row1').scrollLeft=700")
        try await settle(webView)
        let (x, y) = try await fraction(of: "#row1 figure:nth-child(4) h3", in: webView)
        let context = try #require(await controller.readElement(atX: x, y: y))
        #expect(context.role == "heading")
        #expect(context.text == "Screen 4")
    }

    @Test func picksAButtonInsideANestedScrollerAndAfterAPageScroll() async throws {
        let (controller, webView, window) = try await makeController()
        _ = window
        _ = try await webView.evaluateJavaScript("window.scrollTo(0,150);document.getElementById('outer').scrollTop=260")
        try await settle(webView)
        let (x, y) = try await fraction(of: "#inner button", in: webView)
        let context = try #require(await controller.readElement(atX: x, y: y))
        #expect(context.role == "button")
        #expect(context.text == "Pay now")
    }
}

/// WAG-280: a pin on a capture maps to the live element by page coordinates.
@MainActor
struct PageElementPageCoordinateTests {
    private func page() async throws -> (WebViewCaptureController, WKWebView, NSWindow) {
        let controller = WebViewCaptureController()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = webView
        controller.register(webView)
        webView.loadHTMLString(PageElementPickTests.fixture, baseURL: nil)
        let deadline = Date().addingTimeInterval(20)
        while webView.isLoading && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        try await Task.sleep(nanoseconds: 300_000_000)
        return (controller, webView, window)
    }

    private func documentCentre(of selector: String, in webView: WKWebView) async throws -> (Double, Double) {
        let raw = try await webView.evaluateJavaScript("(function(){var r=document.querySelector('\(selector)').getBoundingClientRect();return [r.left+r.width/2+window.scrollX,r.top+r.height/2+window.scrollY];})()")
        let values = try #require(raw as? [NSNumber])
        return (values[0].doubleValue, values[1].doubleValue)
    }

    @Test func readsAnElementInViewByItsPageCoordinates() async throws {
        let (controller, webView, window) = try await page()
        _ = window
        let (x, y) = try await documentCentre(of: "h2", in: webView)
        let context = try #require(await controller.readElement(pageX: x, pageY: y))
        #expect(context.role == "heading")
        #expect(context.text == "Onboarding")
    }

    @Test func readsAnElementThatIsNowScrolledOutOfView() async throws {
        let (controller, webView, window) = try await page()
        _ = window
        let (x, y) = try await documentCentre(of: "h1", in: webView)
        // The capture was taken at the top; the page is now scrolled well past the header.
        _ = try await webView.evaluateJavaScript("window.scrollTo(0,400)")
        try await Task.sleep(nanoseconds: 200_000_000)
        let context = try #require(await controller.readElement(pageX: x, pageY: y))
        #expect(context.role == "heading")
        #expect(context.text == "Investor demo")
    }

    @Test func readsAFrameOfASidewaysRowAtFitScale() async throws {
        let (controller, webView, window) = try await page()
        _ = window
        webView.pageZoom = 0.5
        try await Task.sleep(nanoseconds: 300_000_000)
        let (x, y) = try await documentCentre(of: "#row1 figure:nth-child(3) img", in: webView)
        let context = try #require(await controller.readElement(pageX: x, pageY: y))
        #expect(context.role == "image")
        #expect(context.text == "Onboarding screen 3")
        #expect(context.heading == "Screen 3")
    }

    @Test func aPointOnNothingGivesNoElement() async throws {
        let (controller, _, window) = try await page()
        _ = window
        #expect(await controller.readElement(pageX: 5_000, pageY: 9_000) == nil)
    }

    @Test func aCardNamesTheElementOrSaysThereIsNone() {
        let store = CommentsSessionStore()
        store.showsPageElements = true
        #expect(PageElementContext(role: "button", text: "Pay now", selector: "", heading: "").cardLabel == "On the button \"Pay now\"")
        #expect(PageElementContext(role: "image", text: "", selector: "", heading: "").cardLabel == "On the image")
    }
}

@MainActor
struct CommentSurfacesTests {
    @Test func everySurfaceOffersCommentWhileTheAnswerIsOpen() {
        // The review page, the panel, the full page and an own window all pass the case's lock to the one viewer.
        #expect(ArtifactViewerView.canvasTools(isLocked: false, isMarkdown: false, interactAvailable: true) == [.interact, .comment])
        #expect(ArtifactViewerView.canvasTools(isLocked: true, isMarkdown: false, interactAvailable: true) == [.interact])
        #expect(ArtifactViewerView.canvasTools(isLocked: false, isMarkdown: true, interactAvailable: false).isEmpty)
    }

    @Test func oneStoreServesEveryViewerOfACase() {
        let stores = CaseCommentStores()
        let shared = stores.store(forCase: "c1")
        #expect(stores.store(forCase: "c1") === shared)
        #expect(stores.store(forCase: "c2") !== shared)
        let client = KnockClient(socketPath: "/tmp/knock-test-none.sock")
        let panel = ReviewViewModel(client: client, commentsStore: shared)
        let window = ReviewViewModel(client: client, commentsStore: shared)
        let review = ReviewViewModel(client: client, commentsStore: shared)
        #expect(panel.commentsStore === window.commentsStore)
        #expect(window.commentsStore === review.commentsStore)
    }

    @Test func aCommentOnOneSurfaceListsOnTheOthers() async {
        let shared = CommentsSessionStore()
        let panelViewer = ReviewViewModel(client: KnockClient(socketPath: "/tmp/knock-test-none.sock"), commentsStore: shared)
        let windowViewer = ReviewViewModel(client: KnockClient(socketPath: "/tmp/knock-test-none.sock"), commentsStore: shared)
        shared.beginPendingDraft(rect: Rect(x: 0.2, y: 0.2, w: 0.1, h: 0.1), revision: 1, snapshot: Task { nil })
        shared.updateDraftText("Make the header bigger")
        let comment = shared.commitDraftNow()
        await shared.settleCaptures()
        #expect(panelViewer.commentsStore.model.orderedComments.map(\.text) == ["Make the header bigger"])
        #expect(windowViewer.commentsStore.model.orderedComments.first?.id == comment?.id)
    }

    @Test func aPinReadsItsElementIntoTheCardAsSoonAsItIsKnown() async throws {
        let store = CommentsSessionStore()
        store.showsPageElements = true
        let context = PageElementContext(role: "heading", text: "Investor demo", selector: "header > h1", heading: "")
        let read = Task<PageElementContext?, Never> { try? await Task.sleep(nanoseconds: 50_000_000); return context }
        store.beginPendingDraft(rect: Rect(x: 0.2, y: 0.2, w: 0.1, h: 0.1), revision: 1, page: PageViewport(scrollX: 0, scrollY: 0, width: 900, height: 600), snapshot: Task { nil }, element: read)
        store.updateDraftText("bigger")
        let comment = try #require(store.commitDraftNow())
        #expect(store.elementLabel(for: comment) == nil)
        let deadline = Date().addingTimeInterval(20)
        while store.elementLabel(for: comment) == nil && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(store.elementLabel(for: comment) == "On the heading \"Investor demo\"")
    }

    @Test func aPinWithNoElementSaysSoInPlainWords() async throws {
        let store = CommentsSessionStore()
        store.showsPageElements = true
        let read = Task<PageElementContext?, Never> { nil }
        store.beginPendingDraft(rect: Rect(x: 0.2, y: 0.2, w: 0.1, h: 0.1), revision: 1, page: PageViewport(scrollX: 0, scrollY: 0, width: 900, height: 600), snapshot: Task { nil }, element: read)
        store.updateDraftText("here")
        let comment = try #require(store.commitDraftNow())
        let deadline = Date().addingTimeInterval(20)
        while store.elementLabel(for: comment) == nil && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(store.elementLabel(for: comment) == "No page element")
        #expect(!"No page element".contains("\u{2014}"))
    }
}

struct AppDeepLinkTests {
    @Test func backToWaggleOpensOneCaseAndNothingElse() {
        #expect(AppDeepLink.caseId(from: URL(string: "waggle://case/c-1_a")!) == "c-1_a")
        #expect(AppDeepLink.caseId(from: URL(string: "waggle://other/c1")!) == nil)
        #expect(AppDeepLink.caseId(from: URL(string: "https://case/c1")!) == nil)
        #expect(AppDeepLink.caseId(from: URL(string: "waggle://case/a/b")!) == nil)
        #expect(AppDeepLink.caseId(from: URL(string: "waggle://case/")!) == nil)
    }
}
