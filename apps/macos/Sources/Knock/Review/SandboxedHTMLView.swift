import SwiftUI
import WebKit

/// Renders one staged `html_bundle` entry inside the isolated `WKWebView`
/// configuration `HTMLIsolation` builds. This view never adds a script
/// message handler or a user script itself — doing either here would
/// reopen the "no bridge to the app" hole the configuration is built to
/// close.
struct SandboxedHTMLView: NSViewRepresentable {
    let entryURL: URL
    let directoryURL: URL
    let configuration: WKWebViewConfiguration
    /// Registers the live webview so Comment mode can freeze it into a
    /// capture with `WKWebView.takeSnapshot` (docs/stories/KNOCK-11.md).
    /// `nil` when nothing needs to capture this view.
    var captureController: WebViewCaptureController?
    /// HAIL-127: the zoom state. The webview applies `storedScale` with
    /// `pageZoom` (no script, no bridge) and the model hears pinches.
    var zoom: PrototypeZoomModel?
    /// The scale to show; passed in so SwiftUI calls `updateNSView` on a change.
    var magnification: CGFloat = 1
    /// The page's URL hash (`#plans?variant=table`), or `nil` for none. The page is opened at it, and a later
    /// change only sets `location.hash`. Waggle never calls into the page otherwise.
    var fragment: String? = nil
    /// An option link (WAG-276): scroll to an anchor in the page. A new `token` runs it once; one that
    /// arrives before the page has loaded waits for the load. The script is `ArtifactTabs.anchorScript`.
    struct AnchorRequest: Equatable {
        let token: Int
        let anchor: String
    }
    var anchorRequest: AnchorRequest? = nil

    /// Remembers which entry the webview shows, so a new revision (a new staged
    /// path) reloads the same webview in place (HAIL-114).
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedEntry: URL?
        var isLoaded = false
        var lastAnchorToken: Int?
        var pendingAnchor: String?
        var loadedDirectory: URL?
        var loadedFragment: String?
        var pinchToken: PrototypePinchMonitor.Token?
        var panMonitor: PrototypePanMonitor?
        /// The scale the web view shows (it is set synchronously by the worker).
        var appliedScale: CGFloat = 1
        /// The newest zoom request; the worker applies it and any that arrive meanwhile.
        var request: (scale: CGFloat, anchor: CGPoint?)?
        var working = false

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            runPendingAnchor(in: webView)
        }

        func runPendingAnchor(in webView: WKWebView) {
            guard let anchor = pendingAnchor else { return }
            pendingAnchor = nil
            webView.evaluateJavaScript(ArtifactTabs.anchorScript(anchor), completionHandler: nil)
        }
    }

    /// `entry` opened at `fragment`.
    static func url(_ entry: URL, fragment: String?) -> URL {
        guard let fragment, var parts = URLComponents(url: entry, resolvingAgainstBaseURL: false) else { return entry }
        parts.fragment = fragment
        return parts.url ?? entry
    }

    /// The one script a hash change runs: it sets `location.hash` to `fragment`, JSON-quoted so an id never ends the string.
    static func hashScript(_ fragment: String) -> String {
        let data = (try? JSONEncoder().encode(fragment)) ?? Data("\"\"".utf8)
        return "location.hash = " + (String(data: data, encoding: .utf8) ?? "\"\"")
    }

    /// True when the webview shows another entry than `entry` (a new revision's staged path).
    static func needsReload(loaded: URL?, entry: URL) -> Bool { loaded != entry }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        // Registered before the load starts (not after, as before): Comment
        // mode can freeze a capture the instant this view appears
        // (`KNOCK_REVIEW_MODE=comment`, Amendments), and `takeSnapshot` needs
        // `webView` in place to even begin polling for a finished navigation
        // (`WebViewCaptureController`).
        captureController?.register(webView)
        HTMLIsolation.load(entry: Self.url(entryURL, fragment: fragment), directory: directoryURL, into: webView)
        context.coordinator.loadedEntry = entryURL
        context.coordinator.loadedDirectory = directoryURL
        context.coordinator.loadedFragment = fragment
        // The canvas is the viewer's light background wherever the page does
        // not reach (zoomed out). A diagram's page never paints black.
        webView.underPageBackgroundColor = NSColor(Theme.Colors.list)
        // Agent content keeps its own colours (decision 2026-11-11, Dark Mode): the page always sees the light
        // look, so a page written for a white canvas reads the same when Waggle is dark.
        webView.appearance = NSAppearance(named: .aqua)
        if let zoom {
            let coordinator = context.coordinator
            coordinator.pinchToken = PrototypePinchMonitor.install(on: webView, model: zoom)
            coordinator.panMonitor = PrototypePanMonitor.install(
                on: webView,
                pan: { [weak webView] translation in
                    guard let webView else { return }
                    let scale = max(webView.pageZoom, 0.01)
                    let dx = -translation.width / scale, dy = -translation.height / scale
                    webView.evaluateJavaScript("window.scrollBy(\(dx), \(dy))", completionHandler: nil)
                },
                refreshEditable: { [weak webView, weak coordinator] in
                    guard let webView else { return }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 60_000_000)
                        let script = "(function(e){return !!e && (e.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(e.tagName))})(document.activeElement)"
                        let result = try? await webView.evaluateJavaScript(script)
                        coordinator?.panMonitor?.editableFocused = (result as? Bool) ?? false
                    }
                }
            )
            zoom.reloadAction = { [weak webView, weak coordinator] in
                guard let webView, let entry = coordinator?.loadedEntry, let directory = coordinator?.loadedDirectory else { return }
                await PrototypeReload.run(webView, entry: entry, directory: directory)
            }
            zoom.pageWidthReader = { [weak webView] in
                guard let webView else { return nil }
                // The page is laid out at the current zoom, so measure it at
                // 100% (layout is forced by the read) and put the zoom back.
                let zoomNow = webView.pageZoom
                if abs(zoomNow - 1) > 0.0001 { webView.pageZoom = 1 }
                defer { if abs(zoomNow - 1) > 0.0001 { webView.pageZoom = zoomNow } }
                // A diagram page renders its SVG at natural size under
                // `#diagram`; Fit frames that width (scaling a narrow diagram
                // up). Any other page frames its full scroll width.
                let script = "(function(){var s=document.querySelector('#diagram svg');if(s){var r=s.getBoundingClientRect();if(r.width>0)return r.width;}return document.documentElement.scrollWidth;})()"
                guard let raw = try? await webView.evaluateJavaScript(script),
                      let width = (raw as? NSNumber)?.doubleValue, width > 0 else { return nil }
                return (CGFloat(width), webView.bounds.width)
            }
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        applyMagnification(to: nsView, coordinator: context.coordinator)
        applyAnchor(to: nsView, coordinator: context.coordinator)
        guard Self.needsReload(loaded: context.coordinator.loadedEntry, entry: entryURL) else {
            if fragment != context.coordinator.loadedFragment, let fragment {
                context.coordinator.loadedFragment = fragment
                nsView.evaluateJavaScript(Self.hashScript(fragment), completionHandler: nil)
            }
            return
        }
        context.coordinator.loadedEntry = entryURL
        context.coordinator.loadedDirectory = directoryURL
        context.coordinator.loadedFragment = fragment
        context.coordinator.isLoaded = false
        HTMLIsolation.load(entry: Self.url(entryURL, fragment: fragment), directory: directoryURL, into: nsView)
    }

    /// Runs a new anchor request now when the page has loaded, else after the load.
    private func applyAnchor(to webView: WKWebView, coordinator: Coordinator) {
        guard let request = anchorRequest, request.token != coordinator.lastAnchorToken else { return }
        coordinator.lastAnchorToken = request.token
        coordinator.pendingAnchor = request.anchor
        if coordinator.isLoaded { coordinator.runPendingAnchor(in: webView) }
    }

    /// Zooms around the pointer: the page point under `anchor` stays under it
    /// (`PrototypeCanvas.scrollOrigin`), and the page scrolls there. Requests
    /// that arrive while one is applying collapse into the newest.
    private func applyMagnification(to webView: WKWebView, coordinator: Coordinator) {
        guard abs(coordinator.appliedScale - magnification) > 0.0001 || abs(webView.pageZoom - magnification) > 0.0001 else { return }
        var anchor = zoom?.takePendingAnchor()
        if let fraction = zoom?.pendingAnchorFraction {
            zoom?.pendingAnchorFraction = nil
            anchor = CGPoint(x: fraction.x * webView.bounds.width, y: fraction.y * webView.bounds.height)
        }
        coordinator.request = (magnification, anchor)
        guard !coordinator.working else { return }
        coordinator.working = true
        Task { @MainActor [weak webView] in
            while let webView, let request = coordinator.request {
                coordinator.request = nil
                await Self.apply(request.scale, anchor: request.anchor, to: webView, from: coordinator.appliedScale)
                coordinator.appliedScale = request.scale
            }
            coordinator.working = false
        }
    }

    /// HAIL-143: zoom is `pageZoom`, which re-lays the page out like browser
    /// zoom (the layout width becomes view / scale). `setMagnification` only
    /// scaled the rendering, so a zoomed-out page kept its 100% layout width and
    /// covered `scale` x the view. Scroll and page sizes are CSS pixels at the
    /// zoom they were read at, so the page size is read after the zoom changes.
    @MainActor
    private static func apply(_ scale: CGFloat, anchor: CGPoint?, to webView: WKWebView, from oldScale: CGFloat) async {
        let pointer = anchor ?? CGPoint(x: webView.bounds.midX, y: webView.bounds.midY)
        var scroll = CGPoint.zero
        if let raw = try? await webView.evaluateJavaScript("[window.scrollX, window.scrollY]"), let values = raw as? [NSNumber], values.count == 2 {
            scroll = CGPoint(x: values[0].doubleValue, y: values[1].doubleValue)
        }
        webView.pageZoom = scale
        // The web process re-lays the page out for the new zoom asynchronously.
        try? await Task.sleep(nanoseconds: 120_000_000)
        var target = PrototypeCanvas.scrollOrigin(keeping: pointer, scroll: scroll, from: oldScale, to: scale)
        let script = "[document.documentElement.scrollWidth, Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)]"
        if let raw = try? await webView.evaluateJavaScript(script), let values = raw as? [NSNumber], values.count == 2, values[0].doubleValue > 0 {
            let page = CGSize(width: values[0].doubleValue, height: values[1].doubleValue)
            target = PrototypeCanvas.clamped(scroll: target, page: page, viewport: webView.bounds.size, scale: scale)
        }
        _ = try? await webView.evaluateJavaScript("window.scrollTo(\(target.x), \(target.y))")
    }
}
