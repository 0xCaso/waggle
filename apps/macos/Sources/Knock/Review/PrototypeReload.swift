import WebKit

/// What the Reload button needs from the prototype's web view (HAIL-233). A
/// protocol so a unit test can drive the action with a fake.
@MainActor
protocol ReloadableWebView: AnyObject {
    /// Forgets everything the page stored: local and session storage, cookies, caches.
    func clearWebsiteData() async
    /// Loads the bundle entry again, scoped to its revision directory.
    func loadEntry(_ entry: URL, directory: URL)
}

extension WKWebView: ReloadableWebView {
    /// The data store is the bundle's own non-persistent one (`HTMLIsolation.makeConfiguration`),
    /// so this clears only what the sandboxed page wrote. Nothing leaves the Mac.
    func clearWebsiteData() async {
        await configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    func loadEntry(_ entry: URL, directory: URL) {
        HTMLIsolation.load(entry: entry, directory: directory, into: self)
    }
}

/// "Reload the prototype: back to its first screen". The same sandboxed web view
/// and configuration load the same entry; only the page's state is thrown away.
@MainActor
enum PrototypeReload {
    static let tooltip = "Reload the prototype: back to its first screen"

    static func run(_ webView: ReloadableWebView, entry: URL, directory: URL) async {
        await webView.clearWebsiteData()
        webView.loadEntry(entry, directory: directory)
    }
}
