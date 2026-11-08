import Foundation

/// The Previews page's "Ask before opening links" toggle (HAIL-52 contract):
/// on by default. Off opens a write-up's link straight in the browser; on
/// keeps today's confirmation (`MarkdownLinkGate`, HAIL-33). Persisted in
/// `UserDefaults`, unlike `HTMLPreviewSettings`' `KNOCK_HOME` marker file:
/// this toggle carries no safety consequence (the isolation self-check does),
/// so it does not need that same KNOCK_HOME-scoped isolation - a test or
/// evidence copy already gets its own `UserDefaults` domain from its own
/// bundle id (`KNOCK_BUNDLE_ID`), the same way the running app does from its
/// real one.
enum LinkConfirmSettings {
    private static let key = "linkConfirmDisabled"

    static func isDisabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func setDisabled(_ disabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(disabled, forKey: key)
    }

    /// Whether a tapped link should still be gated behind a confirmation -
    /// the single value the Previews toggle shows and `MarkdownView` reads.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        !isDisabled(defaults: defaults)
    }
}

/// Whether a tapped write-up link opens straight away or waits for a
/// confirmation. Pure and free of `UserDefaults`, so the decision itself is
/// testable without a settings fixture; `LinkConfirmSettings.isEnabled()`
/// supplies the one input a real call site reads.
enum LinkOpenDecision: Equatable {
    case openDirectly
    case confirm
}

enum LinkOpenPolicy {
    static func decide(confirmEnabled: Bool) -> LinkOpenDecision {
        confirmEnabled ? .confirm : .openDirectly
    }
}
