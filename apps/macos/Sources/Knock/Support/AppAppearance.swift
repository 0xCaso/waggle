import AppKit
import SwiftUI

/// The look the human chose in Settings (decision 2026-11-11, Dark Mode): follow macOS, or stay light or dark.
enum AppearanceSetting: String, CaseIterable, Identifiable, Equatable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// `nil` lets every window follow macOS.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    private static let key = "appearance"

    /// The stored value. Nothing stored, or a value this version does not know, reads as `system`.
    static func stored(defaults: UserDefaults = .standard) -> AppearanceSetting {
        defaults.string(forKey: key).flatMap(AppearanceSetting.init(rawValue:)) ?? .system
    }

    static func store(_ setting: AppearanceSetting, defaults: UserDefaults = .standard) {
        defaults.set(setting.rawValue, forKey: key)
    }

    /// `KNOCK_APPEARANCE=<system|light|dark>` wins over the stored value, so an evidence run picks its look
    /// without a click and without a write.
    static func current(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppearanceSetting {
        environment["KNOCK_APPEARANCE"].flatMap(AppearanceSetting.init(rawValue:)) ?? stored(defaults: defaults)
    }
}

/// Sets the look of every window, sheet, popover and menu at once. AppKit-backed controls (TextEditor,
/// TextField, pickers, menus) follow the app's appearance, and each `Theme.Colors` token has a light and a dark
/// value, so chrome and controls always agree. HTML bundle web views keep their own content.
@MainActor
enum AppAppearance {
    /// Applies a setting to the app. `app` is injectable for tests.
    static func apply(_ setting: AppearanceSetting = .current(), to app: NSApplication = NSApplication.shared) {
        app.appearance = setting.appearanceName.flatMap(NSAppearance.init(named:))
    }
}

/// The Settings control's state: stores the choice and applies it at once, with no restart.
@MainActor
final class AppearanceModel: ObservableObject {
    @Published private(set) var setting: AppearanceSetting
    private let defaults: UserDefaults
    private let app: NSApplication

    init(defaults: UserDefaults = .standard, app: NSApplication = NSApplication.shared) {
        self.defaults = defaults
        self.app = app
        setting = AppearanceSetting.stored(defaults: defaults)
    }

    func choose(_ setting: AppearanceSetting) {
        guard setting != self.setting else { return }
        AppearanceSetting.store(setting, defaults: defaults)
        self.setting = setting
        AppAppearance.apply(setting, to: app)
    }
}
