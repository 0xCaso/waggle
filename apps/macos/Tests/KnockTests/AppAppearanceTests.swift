import AppKit
import Foundation
import Testing
@testable import Knock

/// Dark Mode (decision 2026-11-11): one stored value, `system` by default, applied to the whole app at once.
@MainActor
struct AppAppearanceTests {
    private func scratchDefaults() -> UserDefaults {
        let name = "appearance-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func theDefaultIsSystem() {
        let defaults = scratchDefaults()
        #expect(AppearanceSetting.stored(defaults: defaults) == .system)
        #expect(AppearanceSetting.current(defaults: defaults, environment: [:]) == .system)
    }

    @Test func theStoredValueIsReadBack() {
        let defaults = scratchDefaults()
        for setting in AppearanceSetting.allCases {
            AppearanceSetting.store(setting, defaults: defaults)
            #expect(AppearanceSetting.stored(defaults: defaults) == setting)
        }
    }

    @Test func anUnknownStoredValueReadsAsSystem() {
        let defaults = scratchDefaults()
        defaults.set("sepia", forKey: "appearance")
        #expect(AppearanceSetting.stored(defaults: defaults) == .system)
    }

    @Test func theEnvironmentWinsOverTheStoredValue() {
        let defaults = scratchDefaults()
        AppearanceSetting.store(.light, defaults: defaults)
        #expect(AppearanceSetting.current(defaults: defaults, environment: ["KNOCK_APPEARANCE": "dark"]) == .dark)
        #expect(AppearanceSetting.current(defaults: defaults, environment: ["KNOCK_APPEARANCE": "nope"]) == .light)
    }

    @Test func applySetsTheLookOnTheApp() {
        let app = NSApplication.shared
        let before = app.appearance
        defer { app.appearance = before }
        AppAppearance.apply(.dark, to: app)
        #expect(app.appearance?.name == .darkAqua)
        AppAppearance.apply(.light, to: app)
        #expect(app.appearance?.name == .aqua)
        AppAppearance.apply(.system, to: app)
        #expect(app.appearance == nil)
    }

    @Test func choosingStoresAndAppliesAtOnce() {
        let app = NSApplication.shared
        let before = app.appearance
        defer { app.appearance = before }
        let defaults = scratchDefaults()
        let model = AppearanceModel(defaults: defaults, app: app)
        #expect(model.setting == .system)
        model.choose(.dark)
        #expect(model.setting == .dark)
        #expect(AppearanceSetting.stored(defaults: defaults) == .dark)
        #expect(app.appearance?.name == .darkAqua)
        model.choose(.system)
        #expect(app.appearance == nil)
    }

    @Test func noViewUsesASystemDarkDependentInputBackground() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Knock")
        let banned = [
            "textBackgroundColor", "controlBackgroundColor", "windowBackgroundColor",
            "Color(nsColor: .text", "Color(nsColor: .control",
            "Color(nsColor: .windowBackground", "Color(.textBackground", "Color(.controlBackground",
            "Color(.windowBackground",
        ]
        var hits: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for word in banned where text.contains(word) { hits.append("\(url.lastPathComponent): \(word)") }
        }
        #expect(hits.isEmpty, "system dark-dependent colours: \(hits)")
    }

    @Test func everyTextEditorHidesItsScrollBackground() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Knock")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let editors = text.components(separatedBy: "TextEditor(").count - 1
            let hidden = text.components(separatedBy: ".scrollContentBackground(.hidden)").count - 1
            #expect(hidden >= editors, "\(url.lastPathComponent): TextEditor without .scrollContentBackground(.hidden)")
        }
    }
}
