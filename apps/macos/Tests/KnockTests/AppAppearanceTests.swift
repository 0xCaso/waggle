import AppKit
import Foundation
import Testing
@testable import Knock

/// HAIL-234: the app forces the light (Aqua) appearance so AppKit-backed inputs never go dark.
@MainActor
struct AppAppearanceTests {
    @Test func applySetsAquaOnTheApp() {
        let app = NSApplication.shared
        let before = app.appearance
        defer { app.appearance = before }
        app.appearance = NSAppearance(named: .darkAqua)
        AppAppearance.apply(to: app)
        #expect(app.appearance?.name == .aqua)
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
