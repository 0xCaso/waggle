import Foundation

/// The Updates page's "Show a toast when an update is ready" toggle (HAIL-52
/// contract): on by default. Off keeps `UpdateReadyModel` from showing
/// (`UpdaterLogDelegate.updater(_:willInstallUpdateOnQuit:...)` checks this
/// before calling `present`); the update still installs on quit either way -
/// this only ever gates the toast, never the install itself. Persisted in
/// `UserDefaults`, the same way `LinkConfirmSettings` is: no `KNOCK_HOME`
/// safety consequence, so a test or evidence copy's own bundle id already
/// isolates it.
enum UpdateToastSettings {
    private static let key = "updateToastDisabled"

    static func isDisabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func setDisabled(_ disabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(disabled, forKey: key)
    }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        !isDisabled(defaults: defaults)
    }
}

/// The Updates page's status chip (HAIL-52 contract: "'Up to date' / 'Update
/// ready' chip"). Pure so the label rule is testable without a live
/// `UpdateReadyModel`.
enum UpdateReadinessChip {
    static func label(isReady: Bool) -> String {
        isReady ? "Update ready" : "Up to date"
    }
}
