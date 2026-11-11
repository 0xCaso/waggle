import AppKit
import Foundation

/// The daemon's own log file, for the offline banner's "View log" button.
///
/// The daemon creates `<data root>/logs/` (daemon/src/daemon.ts) but writes only `usage.log` there,
/// and a detached daemon has no stderr file. So today no daemon log exists, and the button stays
/// hidden. When a later daemon release writes `logs/daemon.log`, the button shows with no app change.
enum DaemonLog {
    static let fileName = "daemon.log"

    /// The log file when it exists; `nil` otherwise.
    static func existingURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        let url = URL(fileURLWithPath: KnockClient.defaultDataRoot(environment: environment))
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent(fileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Opens the log in the app that handles it; reveals it in Finder when no app can open it.
    @MainActor
    static func open(_ url: URL, workspace: NSWorkspace = .shared) {
        if workspace.urlForApplication(toOpen: url) != nil, workspace.open(url) { return }
        workspace.activateFileViewerSelecting([url])
    }
}
