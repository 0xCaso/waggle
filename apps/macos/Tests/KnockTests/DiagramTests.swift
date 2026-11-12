import Foundation
import Testing
import SwiftUI
import WebKit
@testable import Knock

/// HAIL-141: the .svg sanitising rules, the offline generated wrapper page,
/// and the bundled Mermaid build.
struct DiagramSVGSanitizerTests {
    @Test func stripsScriptElements() {
        let input = #"<svg><script>alert("x")</script><rect/></svg>"#
        let output = DiagramSVGSanitizer.sanitize(input)
        #expect(!output.contains("<script"))
        #expect(!output.contains("alert("))
    }

    @Test func stripsScriptCaseInsensitively() {
        let input = #"<svg><SCRIPT type="text/javascript">x</SCRIPT></svg>"#
        let output = DiagramSVGSanitizer.sanitize(input)
        #expect(!output.lowercased().contains("<script"))
    }

    @Test func stripsEventHandlerAttributes() {
        let input = #"<svg><rect onclick="go()" onload='run()'/></svg>"#
        let output = DiagramSVGSanitizer.sanitize(input)
        #expect(!output.contains("onclick"))
        #expect(!output.contains("onload"))
    }

    @Test func stripsForeignObject() {
        let input = #"<svg><foreignObject><div>html</div></foreignObject><rect/></svg>"#
        let output = DiagramSVGSanitizer.sanitize(input)
        #expect(!output.lowercased().contains("foreignobject"))
        #expect(!output.contains("<div>"))
    }

    @Test func stripsExternalHrefsAndKeepsFragments() {
        let input = "<svg><a href=\"https://evil.example\"><use href=\"#a\"/><image xlink:href=\"http://x\"/></a></svg>"
        let output = DiagramSVGSanitizer.sanitize(input)
        #expect(!output.contains("https://evil.example"))
        #expect(!output.contains("http://x"))
        #expect(output.contains("href=\"#a\""))
    }
}

struct DiagramPageTests {
    @Test func mermaidWrapperHasNoNetworkURLs() {
        let html = DiagramPage.wrapperHTML(source: "flowchart TD\n  A --> B", format: .mermaid)
        #expect(!html.contains("http://"))
        #expect(!html.contains("https://"))
        #expect(!html.contains("//cdn"))
        #expect(html.contains("mermaid.min.js"))
        #expect(html.contains(DiagramPage.titleSentinel))
        #expect(html.contains("Waggle could not draw this diagram"))
    }

    @Test func svgWrapperInlinesTheSanitisedSVGAndHasNoNetworkFetches() {
        let source = "<svg xmlns=\"http://www.w3.org/2000/svg\" onload=\"x()\"><rect width=\"10\" height=\"10\"/></svg>"
        let html = DiagramPage.wrapperHTML(source: source, format: .svg)
        #expect(html.contains("<rect"))
        #expect(!html.contains("onload"))
        #expect(!html.contains("src=\"http"))
        #expect(!html.contains("href=\"http"))
        #expect(!html.contains("xlink:href=\"http"))
    }

    @Test func jsStringEscapesScriptClose() {
        let escaped = DiagramPage.jsString("a </script> b")
        #expect(!escaped.contains("</script>"))
        #expect(escaped.contains("<\\/script>"))
    }

    @Test func svgWrapperDerivesAViewBoxWhenOnlyWidthAndHeight() {
        let source = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"520\" height=\"180\"><rect width=\"10\" height=\"10\"/></svg>"
        let derived = DiagramPage.deriveViewBoxIfMissing(in: source)
        #expect(derived.contains("viewBox=\"0 0 520 180\""))
    }

    @Test func svgWrapperKeepsAnExistingViewBox() {
        let source = "<svg viewBox=\"0 0 10 10\" width=\"520\" height=\"180\"><rect width=\"10\" height=\"10\"/></svg>"
        let derived = DiagramPage.deriveViewBoxIfMissing(in: source)
        #expect(derived.contains("viewBox=\"0 0 10 10\""))
        #expect(!derived.contains("viewBox=\"0 0 520 180\""))
    }

    @Test func svgWrapperDoesNotDeriveAViewBoxFromUnitValuedDimensions() {
        let source = "<svg width=\"100%\" height=\"100%\"><rect width=\"10\" height=\"10\"/></svg>"
        let derived = DiagramPage.deriveViewBoxIfMissing(in: source)
        #expect(!derived.contains("viewBox="))
    }

    @Test func wrappersUseTheLightViewerBackgroundAndNoPagePadding() {
        let svg = DiagramPage.wrapperHTML(source: "<svg width=\"10\" height=\"10\"/>", format: .svg)
        let mmd = DiagramPage.wrapperHTML(source: "flowchart TD\n  A --> B", format: .mermaid)
        for html in [svg, mmd] {
            #expect(html.contains(DiagramPage.pageBackgroundHex))
            #expect(!html.contains("padding: 24px"))
            #expect(!html.contains("max-width: 100%"))
        }
    }

    @Test func mermaidWrapperDrawsTheSvgAtItsNaturalSize() {
        let html = DiagramPage.wrapperHTML(source: "flowchart TD\n  A --> B", format: .mermaid)
        // Mermaid's responsive max-width cap is removed so 100% shows natural
        // size and Fit can scale the produced SVG up.
        #expect(html.contains("maxWidth = \"none\""))
        #expect(html.contains("setAttribute(\"width\""))
    }
}

/// Guards HAIL-141's "Mermaid build bundled in the app resources" acceptance:
/// the resource ships in Knock_Knock.bundle with its MIT license beside it,
/// and it is the real minified build, not a stub.
struct MermaidResourceTests {
    @Test func mermaidBuildAndLicenseAreBundled() throws {
        let url = try #require(MermaidResource.mermaidJSURL())
        #expect(url.lastPathComponent == "mermaid.min.js")

        let license = url.deletingLastPathComponent().appendingPathComponent("LICENSE.txt")
        #expect(FileManager.default.fileExists(atPath: license.path))

        let data = try Data(contentsOf: url)
        #expect(data.count > 100_000)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("mermaid"))
    }
}

/// Renders the real Mermaid wrapper in an isolated `WKWebView` (the same
/// configuration the app uses) and checks it draws a flowchart, not the error
/// state. This caught the `mermaid.render` result being an object (`{ svg }`)
/// rather than a string - a string-only wrapper test cannot see that.
struct DiagramRenderTests {
    @MainActor
    @Test func mermaidWrapperRendersAFlowchart() async throws {
        let mermaid = try #require(MermaidResource.mermaidJSURL())
        let source = "flowchart TD\n    A[Open ask] --> B[Build]\n    B --> C[Ship]"
        let directory = try DiagramPage.makeTempDirectory()
        let entry = try DiagramPage.materialize(
            source: source, format: .mermaid, mermaidJSURL: mermaid, into: directory
        )

        let contentRuleList = try await HTMLIsolation.compiledContentRuleList()
        let configuration = HTMLIsolation.makeConfiguration(contentRuleList: contentRuleList)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        HTMLIsolation.load(entry: entry, directory: directory, into: webView)

        let deadline = Date().addingTimeInterval(20)
        while webView.title != DiagramPage.titleSentinel && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(webView.title == DiagramPage.titleSentinel)

        let html = (try? await webView.evaluateJavaScript("document.getElementById('diagram').innerHTML") as? String) ?? ""
        #expect(html.contains("<svg"))
        #expect(html.contains("Open ask"))
        #expect(html.contains("Ship"))
        #expect(!html.contains("could not draw"))
    }

    @MainActor
    @Test func svgWrapperRendersInTheIsolatedViewer() async throws {
        let source = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 520 180\" width=\"520\" height=\"180\"><rect x=\"10\" y=\"60\" width=\"90\" height=\"44\" rx=\"8\" fill=\"#2f6fed\" /><text x=\"55\" y=\"88\" text-anchor=\"middle\" fill=\"#fff\" font-size=\"13\">Ask</text></svg>"
        let directory = try DiagramPage.makeTempDirectory()
        let entry = try DiagramPage.materialize(source: source, format: .svg, mermaidJSURL: nil, into: directory)

        let contentRuleList = try await HTMLIsolation.compiledContentRuleList()
        let configuration = HTMLIsolation.makeConfiguration(contentRuleList: contentRuleList)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        HTMLIsolation.load(entry: entry, directory: directory, into: webView)

        let deadline = Date().addingTimeInterval(20)
        while webView.title != DiagramPage.titleSentinel && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(webView.title == DiagramPage.titleSentinel)

        let size = (try? await webView.evaluateJavaScript(
            "document.querySelector('rect')?.getBoundingClientRect().width + 'x' + document.querySelector('rect')?.getBoundingClientRect().height"
        ) as? String) ?? ""
        #expect(size == "90x44")

        // The fill must survive a snapshot too: the evidence window shot reads
        // the web view through takeSnapshot, not the DOM.
        let snapshot = try await webView.takeSnapshot(configuration: WKSnapshotConfiguration())
        guard let tiff = snapshot.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            Issue.record("takeSnapshot returned no image")
            return
        }
        var nonWhite = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if c.redComponent < 0.9 || c.greenComponent < 0.9 || c.blueComponent < 0.9 { nonWhite += 1 }
            }
        }
        #expect(nonWhite > 50)
    }
}

/// HAIL-141c: the window-shot composite's frame flip maps a flipped content
/// view's top-down coordinates into the bottom-up drawing space the web view
/// snapshot is drawn in. A non-flipped view is left unchanged.
struct EvidenceCompositeTests {
    private final class Flipped: NSView { override var isFlipped: Bool { true } }
    private final class Plain: NSView { }

    @MainActor
    @Test func unflippedMapsATopDownFrameIntoBottomUpSpace() {
        let flipped = Flipped(frame: NSRect(x: 0, y: 0, width: 1000, height: 872))
        let plain = Plain(frame: NSRect(x: 0, y: 0, width: 1000, height: 872))
        let frame = NSRect(x: 385.5, y: 177, width: 281.5, height: 667)
        let expected = NSRect(x: 385.5, y: 872 - 177 - 667, width: 281.5, height: 667)
        #expect(EvidenceComposite.unflipped(frame, in: flipped) == expected)
        #expect(EvidenceComposite.unflipped(frame, in: plain) == frame)
    }

    /// A 4x1 strip: pixel 0 is under an opaque overlay (both keyed renders black), pixel 1 is half covered by a black
    /// overlay, pixels 2 and 3 show the page. The page snapshot is yellow; the cached tree is grey everywhere.
    @MainActor
    @Test func keyedRendersKeepWhatTheAppDrawsOverThePage() throws {
        func strip(_ pixels: [[UInt8]]) -> NSBitmapImageRep {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels.count, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)!
            for (i, p) in pixels.enumerated() { for c in 0..<4 { rep.bitmapData![i * 4 + c] = p[c] } }
            return rep
        }
        let content = Plain(frame: NSRect(x: 0, y: 0, width: 4, height: 1))
        let cached = strip(Array(repeating: [128, 128, 128, 255], count: 4))
        // The keys as the bitmap's colour space holds them, the way a real render converts them.
        func key(_ color: NSColor, _ share: Double) -> [UInt8] {
            let c = color.usingColorSpace(.deviceRGB)!
            return [c.redComponent, c.greenComponent, c.blueComponent].map { UInt8(($0 * 255 * share).rounded()) } + [255]
        }
        let ka = EvidenceComposite.keyA, kb = EvidenceComposite.keyB
        let a = strip([[0, 0, 0, 255], key(ka, 0.5), key(ka, 1), key(ka, 1)])
        let b = strip([[0, 0, 0, 255], key(kb, 0.5), key(kb, 1), key(kb, 1)])
        let page = NSImage(size: NSSize(width: 4, height: 1))
        page.lockFocus(); NSColor(deviceRed: 1, green: 1, blue: 0, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 4, height: 1).fill(); page.unlockFocus()
        let png = try #require(EvidenceComposite.png(content: content, cached: cached, pages: [(page, content.bounds)], keys: (a, b)))
        let out = try #require(NSBitmapImageRep(data: png))
        // The stored samples, not `colorAt`: that converts through the PNG's profile, which is not linear.
        func rgb(_ x: Int) -> [Int] { (0..<3).map { Int(out.bitmapData![x * out.bitsPerPixel / 8 + $0]) } }
        let pageColor = rgb(3)
        #expect(pageColor[0] > 240 && pageColor[1] > 240 && pageColor[2] < 10)
        #expect(rgb(2) == pageColor)
        #expect(rgb(0) == [0, 0, 0])
        // Half covered by black: half of the page.
        #expect(zip(rgb(1), pageColor).allSatisfy { abs($0 - $1 / 2) <= 3 })
    }
}

/// The evidence render puts a SwiftUI shadow on the side the screen shows it: `cacheDisplay` alone mirrors it.
struct EvidenceShadowTests {
    @MainActor
    @Test func evidenceRenderKeepsAShadowBelowItsShape() throws {
        let root = ZStack {
            Color.white
            Rectangle().fill(Color.black).frame(width: 40, height: 20)
                .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 12)
        }
        .frame(width: 100, height: 100)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let rep = try #require(EvidenceComposite.render(host))
        // Rows are top-down; the shape spans 40...60.
        func brightness(_ row: Int) -> CGFloat {
            rep.colorAt(x: rep.pixelsWide / 2, y: row * rep.pixelsHigh / 100)?.brightnessComponent ?? -1
        }
        #expect(brightness(68) < brightness(32))
        #expect(brightness(32) > 0.95)
        // The render leaves the live layers as they were.
        let layer = try #require(host.layer)
        let shadowed = try #require(EvidenceComposite.flippedShadowLayers(in: layer).first)
        #expect(shadowed.shadowOffset.height == 12)
    }
}
