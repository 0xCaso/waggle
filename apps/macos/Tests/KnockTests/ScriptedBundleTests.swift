import Testing
import Foundation
import WebKit
@testable import Knock

/// WAG-292: a bundle whose body is built by its inline script renders under the exact configuration the
/// review stage uses (`HTMLIsolation`), so the DOM holds what the script built.
@MainActor
struct ScriptedBundleTests {
    static let fixtureDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/scripted-body", isDirectory: true)

    private func loaded(_ entry: URL, directory: URL) async throws -> WKWebView {
        let list = try await HTMLIsolation.compiledContentRuleList()
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1000, height: 800),
            configuration: HTMLIsolation.makeConfiguration(contentRuleList: list)
        )
        HTMLIsolation.load(entry: entry, directory: directory, into: webView)
        return webView
    }

    /// The text of `selector`, polled until the page has built it or the wait ends.
    private func text(_ selector: String, in webView: WKWebView) async throws -> String {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            let raw = try? await webView.evaluateJavaScript("(document.querySelector('\(selector)')||{}).textContent||''")
            if let text = raw as? String, !text.isEmpty { return text }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return ""
    }

    @Test func contentBuiltByTheInlineScriptIsInTheDOM() async throws {
        let webView = try await loaded(Self.fixtureDirectory.appendingPathComponent("index.html"), directory: Self.fixtureDirectory)
        #expect(try await text("#built", in: webView) == "A · first")
        let tabs = try await webView.evaluateJavaScript("document.querySelectorAll('[data-tabs] button').length")
        #expect((tabs as? Int) == 3)
    }

    /// A tab click runs the page's own handler, so the script is live and not a still.
    @Test func aHandlerTheScriptAttachedRuns() async throws {
        let webView = try await loaded(Self.fixtureDirectory.appendingPathComponent("index.html"), directory: Self.fixtureDirectory)
        _ = try await text("#built", in: webView)
        _ = try await webView.evaluateJavaScript("document.querySelector('[data-v=b]').click()")
        #expect(try await text("#built", in: webView) == "B · second")
    }
}
