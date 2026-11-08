import Testing
import Foundation
import WebKit
@testable import Knock

/// Loads apps/macos/Tests/Fixtures/isolation/index.html through the exact
/// same isolation configuration `SandboxedHTMLView` uses in production
/// (`HTMLIsolation.compiledContentRuleList()` / `makeConfiguration()`), and
/// asserts every escape attempt on that page fails. The fixture reports its
/// own result via the page title only (docs/stories/KNOCK-10.md), so this
/// test never needs a script message handler of its own - adding one would
/// undermine the very property it is checking.
@MainActor
struct IsolationTests {
    enum TestError: Error {
        case timedOut(lastTitle: String)
    }

    static let fixtureDirectory: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/isolation", isDirectory: true)
    }()

    @Test func selfCheckCompiles() async throws {
        // The app-wide gate this story falls back on when this fails.
        _ = try await HTMLIsolation.compiledContentRuleList()
    }

    @Test func everyIsolationEscapeIsBlocked() async throws {
        let contentRuleList = try await HTMLIsolation.compiledContentRuleList()
        let configuration = HTMLIsolation.makeConfiguration(contentRuleList: contentRuleList)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)

        let entry = Self.fixtureDirectory.appendingPathComponent("index.html")
        HTMLIsolation.load(entry: entry, directory: Self.fixtureDirectory, into: webView)

        let title = try await waitForTitle(webView, timeout: 20)
        #expect(title == "ISOLATION_OK", "isolation escape(s) succeeded: \(title)")
    }

    /// Polls `webView.title` until it stops reading the fixture's initial
    /// "isolation-pending" placeholder, or `timeout` elapses.
    private func waitForTitle(_ webView: WKWebView, timeout: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let title = webView.title, title != "isolation-pending", !title.isEmpty {
                return title
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw TestError.timedOut(lastTitle: webView.title ?? "")
    }

    private func withTempHome(_ body: ([String: String]) async throws -> Void) async rethrows {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("knock-isolation-gate-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(["KNOCK_HOME": dir.path])
    }

    /// HAIL-47: `KnockApp.init()` fires `prewarmWebViewIfNeeded()` at launch
    /// so WebKit's own one-time WebContent-process spin-up (measured at
    /// ~110ms for the first `WKWebView` a process ever creates) lands during
    /// launch, not on the operator's first click that reveals an
    /// `html_bundle`. A fresh `IsolationGate` instance, not `.shared`: the
    /// self-check result must not leak in from an earlier test in the same
    /// process.
    @Test func prewarmRunsTheSelfCheckAndCompletesWhenEnabled() async throws {
        try await withTempHome { env in
            let gate = IsolationGate()
            #expect(!gate.isChecked)
            await gate.prewarmWebViewIfNeeded(environment: env)
            #expect(gate.isChecked)
            #expect(gate.htmlPreviewAvailable)
        }
    }

    /// The self-check still runs (so a later real load never re-runs it),
    /// but no `WKWebView` needs creating when HTML preview is off in
    /// Settings - there is nothing for `ArtifactPreviewCard`/
    /// `ReviewViewModel` to show either way.
    @Test func prewarmSkipsTheWebViewWhenHTMLPreviewIsDisabled() async throws {
        try await withTempHome { env in
            HTMLPreviewSettings.setDisabled(true, environment: env)
            let gate = IsolationGate()
            await gate.prewarmWebViewIfNeeded(environment: env)
            #expect(gate.isChecked)
        }
    }
}
