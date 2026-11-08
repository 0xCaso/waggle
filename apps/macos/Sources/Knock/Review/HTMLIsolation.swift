import WebKit

/// The four isolation rules a staged HTML bundle must render under
/// (docs/protocol-mvp.md "HTML preview isolation"). Both the production
/// preview view and the isolation test call into this file, so the test
/// exercises the real configuration, not a copy of it.
///
/// Every member touches WebKit UI types (`WKWebView`, `WKWebViewConfiguration`,
/// `WKContentRuleListStore`), which are main-actor isolated; this whole type
/// is `@MainActor` rather than isolating each function separately.
@MainActor
enum HTMLIsolation {
    static let contentRuleListIdentifier = "knock.preview.isolation"

    /// Blocks every URL that is not `file://`. Rule 1 blocks everything;
    /// rule 2 (`ignore-previous-rules`) un-blocks `file:` matches only,
    /// because WebKit content rule lists evaluate top to bottom and
    /// `ignore-previous-rules` only cancels rules that precede it for a
    /// matching URL. This is one of two independent restrictions on file
    /// access: this rule list stops non-file network access (fetch, image,
    /// iframe to http(s)/ws/data/...); `loadFileURL(_:allowingReadAccessTo:)`
    /// separately stops `file://` reads outside the one revision directory.
    static let contentRuleListJSON = """
    [
      { "trigger": { "url-filter": ".*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": "^file:" }, "action": { "type": "ignore-previous-rules" } }
    ]
    """

    enum SelfCheckError: Error, Equatable {
        case compileFailed
    }

    /// Compiles the content rule list. Failure here is the story's
    /// "isolation self-check fails at startup" case: the caller must fall
    /// back to screenshot-only review rather than render untrusted HTML
    /// without this layer.
    static func compiledContentRuleList() async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: contentRuleListIdentifier,
                encodedContentRuleList: contentRuleListJSON
            ) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: error ?? SelfCheckError.compileFailed)
                }
            }
        }
    }

    /// Builds the configuration every staged HTML bundle renders with:
    /// a non-persistent data store and the compiled content rule list.
    /// Never add a `WKScriptMessageHandler` or a `WKUserScript` to the
    /// controller this returns — that is the "no bridge to the app" rule.
    static func makeConfiguration(contentRuleList: WKContentRuleList) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        controller.add(contentRuleList)
        configuration.userContentController = controller
        return configuration
    }

    /// Loads `entry`, scoped to `directory` (the staged revision directory)
    /// per `loadFileURL(_:allowingReadAccessTo:)`.
    static func load(entry: URL, directory: URL, into webView: WKWebView) {
        webView.loadFileURL(entry, allowingReadAccessTo: directory)
    }
}
