import Foundation

/// The `HTML preview` toggle (KNOCK-17). HTML bundles render only when the
/// isolation self-check passed AND the toggle has not been turned off. The
/// toggle is on by default when the self-check passed, so the operator can
/// ship screenshot-only by turning it off.
///
/// The off state is a marker file under the `KNOCK_HOME`-scoped data root
/// (`KnockClient.defaultDataRoot`), not `UserDefaults`: like `OnboardingState`
/// it respects `KNOCK_HOME` (a test or evidence run can never flip the
/// operator's real setting) and `knock uninstall --purge` resets it by deleting
/// the data root. A marker file present = off; absent = the default (on when
/// isolation passed).
enum HTMLPreviewSettings {
    static func markerURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        URL(fileURLWithPath: KnockClient.defaultDataRoot(environment: environment))
            .appendingPathComponent("html-preview-off")
    }

    static func isDisabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        FileManager.default.fileExists(atPath: markerURL(environment: environment).path)
    }

    static func setDisabled(
        _ disabled: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let url = markerURL(environment: environment)
        if disabled {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: url.path, contents: nil)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Whether HTML preview actually runs for a `html_bundle` case: the
    /// self-check must have passed and the toggle must not be off. This is the
    /// single gate `ReviewViewModel` reads; the Settings toggle shows this same
    /// value and is disabled when the self-check failed.
    static func isEnabled(
        isolationPassed: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        isolationPassed && !isDisabled(environment: environment)
    }
}
