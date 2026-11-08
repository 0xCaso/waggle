import Foundation
import WebKit

/// The app-wide HTML isolation self-check (docs/stories/KNOCK-10.md: "If the
/// isolation self-check fails at startup, HTML preview is disabled and
/// bundles show a notice with screenshot-only review"). Runs once and
/// caches the result: a `WKContentRuleList` compile failure means the
/// isolation layer is unavailable on this system for the whole session, not
/// just for one case, so every `html_bundle` case falls back together.
@MainActor
final class IsolationGate: ObservableObject {
    static let shared = IsolationGate()

    @Published private(set) var isChecked = false
    @Published private(set) var htmlPreviewAvailable = false

    private var compiledList: WKContentRuleList?

    func runSelfCheckIfNeeded() async {
        guard !isChecked else { return }
        do {
            compiledList = try await HTMLIsolation.compiledContentRuleList()
            htmlPreviewAvailable = true
        } catch {
            htmlPreviewAvailable = false
        }
        isChecked = true
    }

    /// `nil` when the self-check has not run yet or failed; callers must
    /// check `htmlPreviewAvailable` first.
    func makeConfiguration() -> WKWebViewConfiguration? {
        guard let compiledList else { return nil }
        return HTMLIsolation.makeConfiguration(contentRuleList: compiledList)
    }

    /// Pays WebKit's own one-time WebContent-process spin-up cost during
    /// launch instead of on the operator's first click that reveals an
    /// `html_bundle` (HAIL-47: measured on this machine at ~110ms for the
    /// first `WKWebView` a process ever creates, ~1ms for every one after -
    /// without this, that ~110ms landed on whichever row happened to be the
    /// first prototype the operator opened, in either the case pane's small
    /// preview card or the review workspace's stage). A no-op when the
    /// self-check fails or HTML preview is off in Settings - there is
    /// nothing to warm either way, `ArtifactPreviewCard`/`ReviewViewModel`
    /// already fall back to the unavailable state for both. The created
    /// view is never shown or kept; only the process spin-up it triggers
    /// matters.
    func prewarmWebViewIfNeeded(environment: [String: String] = ProcessInfo.processInfo.environment) async {
        await runSelfCheckIfNeeded()
        guard HTMLPreviewSettings.isEnabled(isolationPassed: htmlPreviewAvailable, environment: environment),
              let configuration = makeConfiguration() else { return }
        _ = WKWebView(frame: .zero, configuration: configuration)
    }
}
