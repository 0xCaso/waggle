import Testing
import Foundation
import SwiftUI
@testable import Knock

/// HAIL-164: every test uses a temp directory. None touches the real Claude app folder.
@MainActor
struct ClaudeDesktopConfigTests {
    private func makeConfig() throws -> (ClaudeDesktopConfig, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knock-claude-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("Library/Application Support/Claude")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (ClaudeDesktopConfig(fileURL: dir.appendingPathComponent("claude_desktop_config.json")), root)
    }

    private func fakeBinary(in root: URL) throws -> String {
        let url = root.appendingPathComponent("knock")
        try Data().write(to: url)
        return url.path
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private let others = """
    {"theme":"dark","mcpServers":{"dayflow":{"command":"/x/dayflow","args":["a"],"env":{"K":"v"}},"pencil":{"command":"/x/pencil"}}}
    """

    @Test func mergeKeepsOtherServersAndKeys() throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }
        try others.write(to: config.fileURL, atomically: true, encoding: .utf8)
        let bin = try fakeBinary(in: root)

        try config.add(binaryPath: bin)

        let result = try json(config.fileURL)
        #expect(result["theme"] as? String == "dark")
        let servers = try #require(result["mcpServers"] as? [String: Any])
        let original = try #require(JSONSerialization.jsonObject(with: Data(others.utf8)) as? [String: Any])
        let originalServers = try #require(original["mcpServers"] as? [String: Any])
        #expect(NSDictionary(dictionary: servers["dayflow"] as! [String: Any]).isEqual(to: originalServers["dayflow"] as! [String: Any]))
        #expect(NSDictionary(dictionary: servers["pencil"] as! [String: Any]).isEqual(to: originalServers["pencil"] as! [String: Any]))
        let knock = try #require(servers["waggle"] as? [String: Any])
        #expect(knock["command"] as? String == bin)
        #expect(knock["args"] as? [String] == ["mcp"])
        #expect((knock["env"] as? [String: String]) == ["KNOCK_RUNTIME": "claude"])
    }

    @Test func missingFileIsCreatedWithOnlyWaggle() throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }
        try config.add(binaryPath: try fakeBinary(in: root))
        let result = try json(config.fileURL)
        #expect(Set(result.keys) == ["mcpServers"])
        #expect(Set((result["mcpServers"] as! [String: Any]).keys) == ["waggle"])
        #expect(!FileManager.default.fileExists(atPath: config.backupURL.path))
    }

    @Test func invalidJsonChangesNothing() throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }
        let broken = "{ not json"
        try broken.write(to: config.fileURL, atomically: true, encoding: .utf8)

        #expect(throws: ClaudeDesktopConfig.ConfigError.unreadable) {
            try config.add(binaryPath: "/bin/knock")
        }
        #expect(try String(contentsOf: config.fileURL, encoding: .utf8) == broken)
        #expect(!FileManager.default.fileExists(atPath: config.backupURL.path))
        #expect(config.status() == .unreadable)
    }

    @Test func backupHoldsTheFileAsItWasBeforeTheChange() throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }
        try others.write(to: config.fileURL, atomically: true, encoding: .utf8)

        try config.add(binaryPath: try fakeBinary(in: root))

        #expect(config.backupURL.lastPathComponent == "claude_desktop_config.json.knock-backup")
        #expect(try String(contentsOf: config.backupURL, encoding: .utf8) == others)
    }

    @Test func laterChangesKeepTheFirstBackup() throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }
        try others.write(to: config.fileURL, atomically: true, encoding: .utf8)
        let binary = try fakeBinary(in: root)

        try config.add(binaryPath: binary)
        try config.remove()
        try config.add(binaryPath: binary)

        #expect(try String(contentsOf: config.backupURL, encoding: .utf8) == others)
    }

    @Test func removeTakesOutOnlyKnock() throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }
        try others.write(to: config.fileURL, atomically: true, encoding: .utf8)
        try config.add(binaryPath: try fakeBinary(in: root))

        try config.remove()

        let result = try json(config.fileURL)
        let servers = try #require(result["mcpServers"] as? [String: Any])
        #expect(Set(servers.keys) == ["dayflow", "pencil"])
        #expect(result["theme"] as? String == "dark")
    }

    @Test func statusReadsTheFile() throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(config.status() == .notConnected)
        let bin = try fakeBinary(in: root)
        try config.add(binaryPath: bin)
        #expect(config.status() == .connected)
        try FileManager.default.removeItem(atPath: bin)
        #expect(config.status() == .notConnected)
        try config.add(binaryPath: try fakeBinary(in: root))
        try config.remove()
        #expect(config.status() == .notConnected)
    }

    @Test func modelShowsTheUnreadableMessageAndChangesNothing() throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }
        try "[1,2".write(to: config.fileURL, atomically: true, encoding: .utf8)
        let model = ClaudeAppModel(config: config, binaryPath: { "/bin/knock" })
        model.confirmAdd()
        #expect(model.errorMessage == "Waggle could not read the Claude app's settings file. Nothing was changed.")
        #expect(model.canShowFile)
        #expect(!model.justAdded)
    }

    @Test func modelConnectsAndRemoves() throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = try fakeBinary(in: root)
        let model = ClaudeAppModel(config: config, binaryPath: { bin })
        #expect(!model.isConnected)
        model.connectTapped()
        #expect(model.showsConfirm)
        model.confirmAdd()
        #expect(model.isConnected && model.justAdded)
        model.remove()
        #expect(!model.isConnected && !model.justAdded)
    }

    @Test func theClaudeRowRendersBothPlaces() throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ClaudeAppModel(config: config, binaryPath: { nil })
        let view = ClaudeRuntimeGroupView(
            claudeCodeRow: .init(runtime: .claude, status: .connected, plugin: .plugin),
            appModel: model, showsDivider: true, onConnect: {}, onRetry: {}, onRemoveOldEntry: {})
            .frame(width: 560)
        let image = ImageRenderer(content: view).nsImage
        #expect(image != nil)
        #expect(Runtime.claude.displayName == "Claude Code")
    }

    // HAIL-172: the Settings content column at its narrowest (820 window - 210 sidebar - 2 x 28 page padding - 2 x 16 card padding).
    private let narrowestContentWidth: CGFloat = 522

    /// Renders the place row and measures the trailing button's ink: by walking the pixel columns in from the
    /// right edge until the gap before the text.
    private func renderedButtonWidth(_ model: ClaudeAppModel, width: CGFloat) throws -> CGFloat {
        let view = ClaudeAppPlaceRow(model: model)
            .frame(width: width)
            .background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        if let dir = ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_DIR"], !dir.isEmpty {
            renderer.scale = 2
            if let big = renderer.nsImage?.tiffRepresentation, let bigRep = NSBitmapImageRep(data: big),
               let png = bigRep.representation(using: .png, properties: [:]) {
                let name = "claude-app-row-\(model.isConnected ? "connected" : "not-connected")-\(Int(width)).png"
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
        // Walk the columns from the right edge. The button's top and bottom outline put ink in every
        // column it covers; the 10 pt gap before the text column is empty.
        func hasInk(_ x: Int) -> Bool {
            (0..<rep.pixelsHigh).contains { y in
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return c.alphaComponent > 0.1 && (c.redComponent < 0.97 || c.greenComponent < 0.97 || c.blueComponent < 0.97)
            }
        }
        var x = rep.pixelsWide - 1
        while x >= 0, !hasInk(x) { x -= 1 }
        let right = x
        while x >= 0, hasInk(x) { x -= 1 }
        return CGFloat(right - x)
    }

    private func naturalWidth<V: View>(_ view: V) -> CGFloat {
        NSHostingView(rootView: view.fixedSize()).fittingSize.width
    }

    @Test func theButtonKeepsItsNaturalWidthAtTheNarrowestSettingsWidth() throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }

        let notConnected = ClaudeAppModel(config: config, binaryPath: { nil })
        #expect(!notConnected.isConnected)
        let connectNatural = naturalWidth(OnboardingSmallButton(icon: "bolt.fill", title: "Connect", action: {}))
        #expect(connectNatural > 60)
        // 522 is the real minimum. 380 is a stress width: it squeezes the old layout even with the test's font metrics.
        for width in [narrowestContentWidth, 380] {
            let rendered = try renderedButtonWidth(notConnected, width: width)
            #expect(abs(rendered - connectNatural) < 3, "Connect at \(width) pt")
        }

        try config.add(binaryPath: try fakeBinary(in: root))
        let connected = ClaudeAppModel(config: config, binaryPath: { nil })
        #expect(connected.isConnected)
        let removeNatural = naturalWidth(SettingsSecondaryButton(icon: "trash", title: "Remove", action: {}))
        #expect(removeNatural > 60)
        for width in [narrowestContentWidth, 380] {
            let rendered = try renderedButtonWidth(connected, width: width)
            #expect(abs(rendered - removeNatural) < 3, "Remove at \(width) pt")
        }
    }
}
