import Testing
import Foundation
import WebKit
@testable import Knock

/// The variant switch of a decision doc reaches a bundle as its URL hash and nothing else: the page opens at
/// `#<question id>`, and a variant sets `location.hash` through the same isolated configuration production uses.
@MainActor
struct QuestionHashTests {
    private func waitForTitle(_ webView: WKWebView, _ wanted: String) async -> String {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if webView.title == wanted { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return webView.title ?? ""
    }

    @Test func aBundleSeesTheQuestionAndTheVariantAsItsHash() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("waggle-hash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = """
        <!doctype html><html><head><title>none</title></head><body><script>
        function route(){ document.title = location.hash; }
        addEventListener("hashchange", route); route();
        </script></body></html>
        """
        let entry = dir.appendingPathComponent("index.html")
        try page.write(to: entry, atomically: true, encoding: .utf8)

        let list = try await HTMLIsolation.compiledContentRuleList()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: HTMLIsolation.makeConfiguration(contentRuleList: list))
        let real = entry.resolvingSymlinksInPath()
        HTMLIsolation.load(entry: SandboxedHTMLView.url(real, fragment: "plans"), directory: dir.resolvingSymlinksInPath(), into: webView)
        #expect(await waitForTitle(webView, "#plans") == "#plans")

        _ = try? await webView.evaluateJavaScript(SandboxedHTMLView.hashScript("plans?variant=table"))
        #expect(await waitForTitle(webView, "#plans?variant=table") == "#plans?variant=table")
    }
}
