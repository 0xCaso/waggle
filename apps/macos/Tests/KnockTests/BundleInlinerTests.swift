import Foundation
import Testing
@testable import Knock

/// WAG-283: "In the browser" shows a bundle's local files without weakening the sandbox.
@Suite struct BundleInlinerTests {
    private func bundle(_ files: [String: String]) throws -> (root: URL, entry: URL) {
        let outer = FileManager.default.temporaryDirectory.appendingPathComponent("inliner-\(UUID().uuidString)")
        let root = outer.appendingPathComponent("bundle b")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try Data("SECRET".utf8).write(to: outer.appendingPathComponent("secret.png"))
        return (root.resolvingSymlinksInPath(), root.appendingPathComponent("index.html").resolvingSymlinksInPath())
    }

    private func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    @Test func inlinesImagesSrcsetCssUrlsAndFonts() throws {
        let (root, entry) = try bundle([
            "index.html": """
            <link rel="stylesheet" href="css/site.css">
            <style>body{background:url('img/bg.png')}</style>
            <div style="background:url(img/bg.png)"></div>
            <img src="img/a b.png" srcset="img/a b.png 1x, img/b.png 2x" alt="x">
            <video poster="img/b.png"><source src="v/clip.mp4"></video>
            <script src="app.js"></script>
            """,
            "css/site.css": "@font-face{font-family:F;src:url(../fonts/f.woff2)} .h{background:url(\"../img/b.png\")}",
            "img/a b.png": "AAA", "img/b.png": "BBB", "img/bg.png": "GGG", "fonts/f.woff2": "FFF", "v/clip.mp4": "MMM",
            "app.js": "var x = '</script>';",
        ])
        let out = BundleInliner.inline(html: try String(contentsOf: entry, encoding: .utf8), entry: entry, root: root)
        #expect(out.contains("src=\"data:image/png;base64,\(b64("AAA"))\""))
        #expect(out.contains("data:image/png;base64,\(b64("BBB")) 2x"))
        #expect(out.contains("url(data:image/png;base64,\(b64("GGG")))"))
        #expect(out.contains("poster=\"data:image/png;base64,\(b64("BBB"))\""))
        #expect(out.contains("src=\"data:video/mp4;base64,\(b64("MMM"))\""))
        #expect(out.contains("url(data:font/woff2;base64,\(b64("FFF")))"))
        #expect(out.contains("url(data:image/png;base64,\(b64("BBB")))"))
        #expect(!out.contains("<link"))
        #expect(!out.contains("href=\"css/site.css\""))
        #expect(out.contains("<script>var x = '<\\/script>';</script>"))
    }

    @Test func skipsRemoteAbsoluteAndOutsideReferences() throws {
        let (root, entry) = try bundle(["index.html": "", "img/a.png": "AAA"])
        let html = """
        <img src="https://example.com/a.png"><img src="//example.com/a.png"><img src="http://x/a.png">
        <img src="data:image/png;base64,QQ=="><img src="/etc/hosts"><img src="file:///etc/hosts">
        <img src="../secret.png"><img src="img/../../secret.png"><img src="img/%2e%2e/%2e%2e/secret.png">
        <img src="missing.png"><div style="background:url(https://example.com/x.png)"></div>
        <link rel="stylesheet" href="https://example.com/a.css">
        """
        let out = BundleInliner.inline(html: html, entry: entry, root: root)
        #expect(out == html)
        #expect(!out.contains(b64("SECRET")))
    }

    @Test func aSymlinkOutOfTheBundleIsNeverRead() throws {
        let (root, entry) = try bundle(["index.html": ""])
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.png"), withDestinationURL: root.deletingLastPathComponent().appendingPathComponent("secret.png"))
        let html = "<img src=\"link.png\">"
        #expect(BundleInliner.inline(html: html, entry: entry, root: root) == html)
    }

    @Test func aBigFileIsLeftAlone() throws {
        let (root, entry) = try bundle(["index.html": ""])
        try Data(count: BundleInliner.maxFileBytes + 1).write(to: root.appendingPathComponent("big.png"))
        let html = "<img src=\"big.png\">"
        #expect(BundleInliner.inline(html: html, entry: entry, root: root) == html)
    }

    @Test func theWrapperFramesTheInlinedCopyAndReplacesOldFiles() throws {
        let (root, entry) = try bundle(["index.html": "<img src=\"a.png\">", "a.png": "AAA"])
        let name = "test-\(UUID().uuidString)"
        let first = try BrowserWrapper.write(entry: entry, root: root, fragment: nil, title: "T", name: name)
        let page = first.deletingLastPathComponent().appendingPathComponent("\(name)-page.html")
        #expect(try String(contentsOf: page, encoding: .utf8).contains(b64("AAA")))
        let wrapper = try String(contentsOf: first, encoding: .utf8)
        #expect(wrapper.contains("\(name)-page.html"))
        #expect(wrapper.contains("sandbox=\"allow-scripts allow-forms\""))
        #expect(!wrapper.contains("allow-same-origin"))
        #expect(wrapper.contains("connect-src 'none'"))
        #expect(wrapper.contains("frame-src file:"))
        try Data("BBB".utf8).write(to: root.appendingPathComponent("a.png"))
        _ = try BrowserWrapper.write(entry: entry, root: root, fragment: nil, title: "T", name: name)
        let again = try String(contentsOf: page, encoding: .utf8)
        #expect(again.contains(b64("BBB")) && !again.contains(b64("AAA")))
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: page)
    }
}
