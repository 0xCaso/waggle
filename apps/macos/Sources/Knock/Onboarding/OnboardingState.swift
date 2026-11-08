import Foundation

/// Whether first-run setup has been completed (the short window, WAG-338: step 1 connected an agent), and where that is
/// recorded. Stored as a marker file under the `KNOCK_HOME`-scoped data root
/// (`KnockClient.defaultDataRoot`) rather than `UserDefaults`: every other
/// piece of Knock state already lives there and respects `KNOCK_HOME`, so a
/// test run or an evidence run with a temp `KNOCK_HOME` can never mark the
/// operator's real profile onboarded, and `knock uninstall --purge` (which
/// deletes the whole data root) naturally resets it too.
enum OnboardingState {
    static func markerURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        URL(fileURLWithPath: KnockClient.defaultDataRoot(environment: environment))
            .appendingPathComponent("onboarded")
    }

    /// The getting started list, the working state and the tour (WAG-338). A missing file next to an old
    /// `onboarded` marker means a person who finished the old setup: `GettingStartedStore` migrates them.
    static func gettingStartedURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        URL(fileURLWithPath: KnockClient.defaultDataRoot(environment: environment))
            .appendingPathComponent("getting-started.json")
    }

    static func isOnboarded(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        FileManager.default.fileExists(atPath: markerURL(environment: environment).path)
    }

    static func markOnboarded(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let url = markerURL(environment: environment)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    /// `KNOCK_SHOW_ONBOARDING=1` forces the window at launch regardless of
    /// the marker file (evidence hook: the orchestrator cannot send
    /// keystrokes to reach the app menu item).
    static func shouldShowAtLaunch(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["KNOCK_SHOW_ONBOARDING"] == "1" || !isOnboarded(environment: environment)
    }
}
