import Foundation

/// Whether this is a test/dev copy of Knock rather than the operator's real
/// install (docs/stories/HAIL-34.md operator report 21:51: "a worker's
/// evidence app window looked exactly like the real Knock (are they tests or
/// real?)"). Active for anything other than the real data root or the real
/// bundle id - deliberately including ordinary local dev builds, e2e builds
/// and evidence builds, per the operator's literal "anything other than ...
/// dev.limone.knock". A copy this active on shows a strip on every window,
/// prefixes every notification title with "[test] ", and leads its menu bar
/// menu with the same label as a disabled item.
enum TestCopyEnvironment {
    /// The one bundle id the real, shipped app carries. Any other id -
    /// including a plain `nil` from an unsigned dev build - counts as a test
    /// copy.
    static let releaseBundleIdentifier = "dev.limone.knock"

    static func isActive(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        if let home = environment["KNOCK_HOME"], !home.isEmpty {
            return true
        }
        return bundleIdentifier != releaseBundleIdentifier
    }

    /// The data root this copy reads and writes (`KnockClient.
    /// defaultDataRoot`, not reimplemented here): the path the strip's
    /// "data in <path>" segment names.
    static var dataRootLabel: String { KnockClient.defaultDataRoot() }

    /// The exact copy the operator gave (docs/stories/HAIL-34.md 21:51),
    /// reused verbatim by the strip, the menu bar menu's leading disabled
    /// item, and (as a prefix) every notification title.
    static var stripLabel: String { "TEST COPY · data in \(dataRootLabel). Not your real Waggle." }
}
