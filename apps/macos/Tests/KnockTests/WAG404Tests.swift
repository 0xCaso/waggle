import Testing
import AppKit
import Foundation
@testable import Knock

/// WAG-404: snip an area, and the New session row.
@MainActor
struct WAG404Tests {
    // MARK: Helpers

    private func session(_ id: String, cwd: String, connectedAt: String = "2026-10-20T09:00:00Z", state: SessionState = .live) -> SessionInfo {
        SessionInfo(
            id: id, taskId: "t-\(id)", runtime: .claude, taskName: id, project: "work/\(id)", branch: nil,
            cwd: cwd, canNudge: true, state: state, connectedAt: connectedAt, lastSeenAt: connectedAt)
    }

    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wag404-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "wag404-\(UUID().uuidString)")! }

    private func writePNG(to url: URL, width: Int = 64, height: Int = 40) {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    @MainActor
    final class FakeHotKeys: HotKeyRegistering {
        var registered: Set<HotKey> = []
        func register(_ key: HotKey, action: @escaping () -> Void) { registered.insert(key) }
        func unregister(_ key: HotKey) { registered.remove(key) }
    }

    struct FakeCapturer: AreaCapturing {
        let outcome: @Sendable (URL) -> AreaCaptureOutcome
        func capture(to file: URL) async -> AreaCaptureOutcome { outcome(file) }
    }

    @MainActor
    final class FakeLauncher: SessionStarting {
        var calls: [(prompt: String, folder: URL, topic: String)] = []
        func start(prompt text: String, folder: URL, topic: String) async -> Bool {
            calls.append((text, folder, topic))
            return true
        }
    }

    private func controller(
        defaults: UserDefaults, hotKeys: FakeHotKeys = FakeHotKeys(), snips: URL,
        sessions: [SessionInfo] = [], launcher: FakeLauncher = FakeLauncher(),
        capturer: AreaCapturing = FakeCapturer(outcome: { _ in .cancelled }),
        screenAccess: Bool = true, onRequest: @escaping () -> Void = {}
    ) throws -> ScreenshotController {
        ScreenshotController(
            source: FolderScreenCaptureSource(directory: try tempFolder()), defaults: defaults, hotKeys: hotKeys,
            capturer: capturer, frontmostApp: { "Safari" },
            hasScreenAccess: { screenAccess }, requestScreenAccess: onRequest, makeLauncher: { launcher },
            folderPicker: { _ in nil }, snipFolder: snips, showsWindows: false,
            loadSessions: { sessions }, loadCases: { [] },
            sendPrompt: { _, _ in SendPromptResult(sent: true, reason: nil) })
    }

    // MARK: Setting, hotkey, menu

    @Test func aCancelWithoutScreenRecordingSaysHowToAllowIt() async throws {
        let d = defaults()
        ScreenshotSettings.setSnip(true, defaults: d)
        var asked = 0
        let c = try controller(defaults: d, snips: try tempFolder(), screenAccess: false, onRequest: { asked += 1 })
        await c.snip()
        #expect(asked == 1)
        #expect(c.noticeText == ScreenshotCopy.snipNeedsAccess)
        #expect(c.panelModel == nil)
    }

    @Test func aCancelWithScreenRecordingShowsNothing() async throws {
        let d = defaults()
        ScreenshotSettings.setSnip(true, defaults: d)
        var asked = 0
        let c = try controller(defaults: d, snips: try tempFolder(), onRequest: { asked += 1 })
        await c.snip()
        #expect(asked == 0)
        #expect(c.noticeText == nil)
    }

    @Test func snipIsOffByDefaultAndStored() {
        let d = defaults()
        #expect(!ScreenshotSettings.snipIsOn(defaults: d))
        ScreenshotSettings.setSnip(true, defaults: d)
        #expect(ScreenshotSettings.snipIsOn(defaults: d))
        #expect(ScreenshotSettings.mode(defaults: d) == .off)
    }

    @Test func snipOffRegistersNoHotkeyAndHidesTheMenuItem() throws {
        let d = defaults(), keys = FakeHotKeys()
        let c = try controller(defaults: d, hotKeys: keys, snips: try tempFolder())
        #expect(keys.registered.isEmpty)
        #expect(!c.snipIsOn)
        ScreenshotSettings.setSnip(true, defaults: d)
        #expect(keys.registered == [.snip])
        ScreenshotSettings.setSnip(false, defaults: d)
        #expect(keys.registered.isEmpty)
    }

    @Test func theTwoShortcutsUseTheRightKeys() {
        #expect(HotKey.snip.keyCode == 13 && HotKey.sendScreenshot.keyCode == 1)
        #expect(HotKey.snip.modifiers != HotKey.sendScreenshot.modifiers)
        #expect(HotKey.snip.rawValue != HotKey.sendScreenshot.rawValue)
    }

    @Test func screenshotModeAndSnipRegisterIndependently() throws {
        let d = defaults(), keys = FakeHotKeys()
        ScreenshotSettings.setMode(.shortcut, defaults: d)
        _ = try controller(defaults: d, hotKeys: keys, snips: try tempFolder())
        #expect(keys.registered == [.sendScreenshot])
    }

    // MARK: Capture

    @Test func aCancelledCaptureShowsNoPanel() async throws {
        let d = defaults()
        ScreenshotSettings.setSnip(true, defaults: d)
        let c = try controller(defaults: d, snips: try tempFolder())
        await c.snip()
        #expect(c.panelModel == nil)
        #expect(c.noticeText == nil)
    }

    @Test func aFailedCaptureShowsOnePlainLine() async throws {
        let d = defaults()
        ScreenshotSettings.setSnip(true, defaults: d)
        let c = try controller(defaults: d, snips: try tempFolder(), capturer: FakeCapturer(outcome: { _ in .failed }))
        await c.snip()
        #expect(c.panelModel == nil)
        #expect(c.noticeText == "Couldn't snip. Check Screen Recording for Waggle in System Settings.")
    }

    @Test func anExitedToolIsToldApartFromACancel() throws {
        let folder = try tempFolder()
        let file = folder.appendingPathComponent("a.png")
        #expect(ScreencaptureAreaCapturer.outcome(status: 0, file: file) == .cancelled)
        #expect(ScreencaptureAreaCapturer.outcome(status: 1, file: file) == .failed)
        try Data().write(to: file)
        #expect(ScreencaptureAreaCapturer.outcome(status: 0, file: file) == .cancelled)
        writePNG(to: file)
        #expect(ScreencaptureAreaCapturer.outcome(status: 0, file: file) == .captured(file))
    }

    @Test func aFakeCaptureOpensThePanelWithTheSizeAndAppLine() async throws {
        let d = defaults()
        ScreenshotSettings.setSnip(true, defaults: d)
        let snips = try tempFolder()
        let c = try controller(
            defaults: d, snips: snips, sessions: [session("s1", cwd: "/work/alpha")],
            capturer: FakeCapturer(outcome: { file in
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                try? rep.representation(using: .png, properties: [:])?.write(to: file)
                return .captured(file)
            }))
        await c.snip()
        let model = try #require(c.panelModel)
        #expect(model.kind == .snip)
        #expect(model.snip?.meta == "640 \u{00D7} 400 \u{00B7} from Safari")
        #expect(model.captures.first?.url.deletingLastPathComponent().path == snips.path)
        #expect(model.rows.count == 1)
        #expect(model.promptText.hasSuffix("Screenshot: \"\(model.captures[0].path)\""))
    }

    // MARK: Snips folder

    @Test func theSnipsFolderKeepsTheNewest50() throws {
        let folder = try tempFolder()
        for i in 0..<55 {
            let url = folder.appendingPathComponent("Snip \(i).png")
            try Data([1]).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(i) * 10)], ofItemAtPath: url.path)
        }
        SnipFiles.prune(in: folder)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.count == 50)
        #expect(names.contains("Snip 54.png"))
        #expect(!names.contains("Snip 0.png") && !names.contains("Snip 4.png"))
        #expect(names.contains("Snip 5.png"))
    }

    @Test func theSnipsFolderFollowsKnockHome() {
        #expect(SnipFiles.folder(root: "/tmp/kh").path == "/tmp/kh/Snips")
    }

    // MARK: New session row

    @Test func newSessionRowIsInAllThreePanels() async throws {
        let d = defaults()
        let c = try controller(defaults: d, snips: try tempFolder(), sessions: [session("s1", cwd: "/work/alpha")])
        let shot = ScreenCapture(url: URL(fileURLWithPath: "/tmp/a.png"), date: Date())
        for kind in [ScreenshotPanelModel.Kind.badge, .shortcut, .snip] {
            let model = c.present(kind: kind, captures: [shot], rows: [], snip: nil)
            #expect(model.newSession != nil)
            #expect(model.newSession?.subtitle == "Claude Code in Terminal")
        }
    }

    @Test func newSessionIsPickedFirstWithNoLiveSession() throws {
        let c = try controller(defaults: defaults(), snips: try tempFolder())
        let shot = ScreenCapture(url: URL(fileURLWithPath: "/tmp/a.png"), date: Date())
        let model = c.present(kind: .snip, captures: [shot], rows: [])
        #expect(model.newSessionPicked)
        #expect(model.canSend)
    }

    @Test func newSessionSendCallsTheLauncherWithThePromptAndFolder() async throws {
        let launcher = FakeLauncher()
        let c = try controller(defaults: defaults(), snips: try tempFolder(), launcher: launcher)
        let shot = ScreenCapture(url: URL(fileURLWithPath: "/tmp/snip one.png"), date: Date())
        let model = c.present(kind: .snip, captures: [shot], rows: [])
        model.note = "Fix this spacing"
        #expect(model.sendLabel.hasPrefix("Start in "))
        await model.send()
        let call = try #require(launcher.calls.first)
        #expect(call.prompt == "Fix this spacing\n\nScreenshot: \"/tmp/snip one.png\"")
        #expect(call.folder == model.pickedFolder)
        #expect(call.topic == "Fix this spacing")
        #expect(model.phase == .started(folder: model.pickedFolderName))
        #expect(ScreenshotCopy.started(in: "alpha") == "Started in alpha")
    }

    @Test func pickingALiveSessionAfterNewSessionSendsToTheSession() async throws {
        var sent: [(String, String)] = []
        let rows = ScreenshotRows.rows(sessions: [session("s1", cwd: "/work/alpha")], cases: [], lastUsed: nil)
        let shot = ScreenCapture(url: URL(fileURLWithPath: "/tmp/a.png"), date: Date())
        let config = NewSessionConfig(
            subtitle: "x", folders: [], defaultFolder: URL(fileURLWithPath: "/work/alpha"),
            start: { _, _, _ in true }, chooseOther: { _ in nil })
        let model = ScreenshotPanelModel(
            kind: .snip, captures: [shot], rows: rows,
            sendPrompt: { id, text in sent.append((id, text)); return SendPromptResult(sent: true, reason: nil) },
            newSession: config)
        #expect(!model.newSessionPicked)
        model.pickNewSession()
        #expect(model.newSessionPicked)
        model.pickSession("s1")
        #expect(!model.newSessionPicked)
        await model.send()
        #expect(sent.first?.0 == "s1")
    }

    @Test func folderMenuDedupesAndOrdersNewestFirstThenTheSavedFolder() {
        let sessions = [
            session("a", cwd: "/work/alpha", connectedAt: "2026-10-20T08:00:00Z"),
            session("b", cwd: "/work/beta", connectedAt: "2026-10-20T10:00:00Z"),
            session("c", cwd: "/work/alpha/", connectedAt: "2026-10-20T09:00:00Z"),
            session("d", cwd: "/work/gone", connectedAt: "2026-10-20T11:00:00Z", state: .ended),
            session("e", cwd: "", connectedAt: "2026-10-20T12:00:00Z"),
        ]
        let list = NewSessionFolders.choices(sessions: sessions, saved: URL(fileURLWithPath: "/work/alpha"))
        #expect(list.map(\.name) == ["beta", "alpha"])
        let withSaved = NewSessionFolders.choices(sessions: sessions, saved: URL(fileURLWithPath: "/home/idea"))
        #expect(withSaved.map(\.name) == ["beta", "alpha", "idea"])
    }

    @Test func otherFolderJoinsTheListAndIsPicked() throws {
        let config = NewSessionConfig(
            subtitle: "x", folders: [FolderChoice(url: URL(fileURLWithPath: "/a"))], defaultFolder: URL(fileURLWithPath: "/a"),
            start: { _, _, _ in true }, chooseOther: { _ in URL(fileURLWithPath: "/picked") })
        let model = ScreenshotPanelModel(
            kind: .snip, captures: [], rows: [], sendPrompt: { _, _ in SendPromptResult(sent: true, reason: nil) },
            newSession: config)
        model.chooseOtherFolder()
        #expect(model.folders.map(\.name) == ["picked", "a"])
        #expect(model.pickedFolderName == "picked")
        #expect(model.newSessionPicked)
    }

    // MARK: Copy and placement

    @Test func launchTargetNamesReadPlainly() {
        #expect(NewSessionFolders.launchTargetName(.claudeTerminal) == "Claude Code in Terminal")
        #expect(NewSessionFolders.launchTargetName(.codexApp) == "Codex in the Codex app")
        #expect(NewSessionFolders.launchTargetName(.conductor) == "Conductor")
    }

    @Test func copyHasNoEmDash() {
        for text in [ScreenshotCopy.snipSub, ScreenshotCopy.snipOnSub, ScreenshotCopy.snipFailed, ScreenshotCopy.snipNotePlaceholder] {
            #expect(!text.contains("\u{2014}"))
        }
        #expect(ScreenshotCopy.snipSub == "Control Shift W opens the crosshair. Waggle sees only the box you draw.")
    }

    @Test func panelOpensToTheRightOfTheBoxOrLeftWhenThereIsNoRoom() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 380, height: 500)
        let right = ScreenshotGeometry.snipPanelOrigin(box: CGRect(x: 100, y: 300, width: 200, height: 150), screen: screen, size: size)
        #expect(right.x + 20 > 300)
        let left = ScreenshotGeometry.snipPanelOrigin(box: CGRect(x: 1000, y: 300, width: 400, height: 150), screen: screen, size: size)
        #expect(left.x + size.width - 20 < 1000)
        let low = ScreenshotGeometry.snipPanelOrigin(box: CGRect(x: 100, y: 0, width: 100, height: 50), screen: screen, size: size)
        #expect(low.y + 20 >= 8)
        let high = ScreenshotGeometry.snipPanelOrigin(box: CGRect(x: 100, y: 850, width: 100, height: 50), screen: screen, size: size)
        #expect(high.y + size.height - 20 <= 900)
    }
}
