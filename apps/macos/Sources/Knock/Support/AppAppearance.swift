import AppKit
import SwiftUI

/// HAIL-234: Waggle draws one fixed light theme (`Theme.Colors`). AppKit-backed controls
/// (TextEditor, TextField, NSTextView, pickers, menus) follow the system appearance, so in dark
/// mode they paint a black background and white text on top of the light theme. Forcing Aqua on
/// the app fixes every window, sheet, popover and menu at once. HTML bundle web views keep their
/// own content: this sets chrome only.
@MainActor
enum AppAppearance {
    static let name: NSAppearance.Name = .aqua

    /// Sets the app-wide appearance. `app` is injectable for tests.
    static func apply(to app: NSApplication = NSApplication.shared) {
        app.appearance = NSAppearance(named: name)
    }
}
