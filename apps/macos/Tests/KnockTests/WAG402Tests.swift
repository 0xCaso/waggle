import Testing
import Foundation
@testable import Knock

/// WAG-402: send a screenshot to a live session.
@MainActor
struct WAG402Tests {
    // MARK: Helpers

    private func session(
        _ id: String, project: String = "work/alpha", runtime: Runtime = .claude, canNudge: Bool = true,
        state: SessionState = .live, connectedAt: String = "2026-10-20T09:00:00Z"
    ) -> SessionInfo {
        SessionInfo(
            id: id, taskId: "t-\(id)", runtime: runtime, taskName: project, project: project, branch: nil,
            cwd: "/tmp/\(id)", canNudge: canNudge, state: state, connectedAt: connectedAt,
            lastSeenAt: connectedAt)
    }

    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wag402-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func drop(_ name: String, in folder: URL, age: TimeInterval = 0) throws {
        let url = folder.appendingPathComponent(name)
        try Data([0x89, 0x50]).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "wag402-\(UUID().uuidString)")!
    }

    private func panelModel(
        kind: ScreenshotPanelModel.Kind = .badge, rows: [ScreenshotSessionRow]? = nil,
        result: @escaping (String) async throws -> SendPromptResult
    ) -> ScreenshotPanelModel {
        let shot = ScreenCapture(url: URL(fileURLWithPath: "/tmp/a.png"), date: Date())
        let rows = rows ?? ScreenshotRows.rows(sessions: [session("s1"), session("s2")], cases: [], lastUsed: nil)
        return ScreenshotPanelModel(kind: kind, captures: [shot], rows: rows, sendPrompt: { id, _ in try await result(id) })
    }

    // MARK: Mode and watch

    @Test func modeIsOffByDefaultAndStored() {
        let d = defaults()
        #expect(ScreenshotSettings.mode(defaults: d) == .off)
        ScreenshotSettings.setMode(.shortcut, defaults: d)
        #expect(ScreenshotSettings.mode(defaults: d) == .shortcut)
    }

    @Test func thumbnailTipNamesTheMacOSOption() {
        #expect(ScreenshotCopy.thumbnailTip == "For the badge to show at once, turn off Show Floating Thumbnail (Command Shift 5 \u{203A} Options).")
        #expect(!ScreenshotCopy.thumbnailTip.contains("\u{2014}"))
    }

    @Test func modeOffStartsNoWatch() throws {
        let source = FolderScreenCaptureSource(directory: try tempFolder())
        let watcher = ScreenshotWatcher(source: source)
        watcher.apply(.off)
        #expect(source.startCount == 0)
        #expect(!watcher.isWatching)
        watcher.apply(.everyShot)
        #expect(source.isRunning)
        watcher.apply(.off)
        #expect(!source.isRunning)
    }

    @Test func newCaptureAsksForTheBadgeOnlyInEveryShotMode() throws {
        let folder = try tempFolder()
        for (mode, expected) in [(ScreenshotMode.everyShot, 1), (.shortcut, 0)] {
            let source = FolderScreenCaptureSource(directory: folder)
            let watcher = ScreenshotWatcher(source: source)
            var badges: [ScreenCapture] = []
            watcher.onBadge = { badges.append($0) }
            watcher.apply(mode)
            try drop("Screenshot \(mode.rawValue).png", in: folder)
            source.scan()
            #expect(badges.count == expected)
        }
    }

    @Test func screenshotsThatExistedAtStartAndOldOnesGetNoBadge() throws {
        let folder = try tempFolder()
        try drop("old.png", in: folder)
        let source = FolderScreenCaptureSource(directory: folder)
        let watcher = ScreenshotWatcher(source: source)
        var count = 0
        watcher.onBadge = { _ in count += 1 }
        watcher.apply(.everyShot)
        source.scan()
        #expect(count == 0)
        try drop("stale.png", in: folder, age: 120)
        source.scan()
        #expect(count == 0)
    }

    @Test func latestReturnsNewestFirstAndNothingWhenOff() throws {
        let folder = try tempFolder()
        try drop("a.png", in: folder, age: 300)
        try drop("b.png", in: folder, age: 10)
        try drop("c.png", in: folder, age: 100)
        try drop("note.txt", in: folder)
        let watcher = ScreenshotWatcher(source: FolderScreenCaptureSource(directory: folder))
        #expect(watcher.latest(3).isEmpty)
        watcher.apply(.shortcut)
        #expect(watcher.latest(3).map(\.url.lastPathComponent) == ["b.png", "c.png", "a.png"])
        #expect(watcher.latest(2).count == 2)
    }

    // MARK: Rows

    @Test func rowsAreLiveOnlyLastUsedFirstAndMarkNonTypeableRows() {
        let sessions = [
            session("a", project: "work/alpha", connectedAt: "2026-10-20T08:00:00Z"),
            session("b", project: "work/beta", connectedAt: "2026-10-20T09:00:00Z"),
            session("c", project: "work/gone", state: .ended),
            session("d", project: "work/codex", runtime: .codex, canNudge: false, connectedAt: "2026-10-20T10:00:00Z"),
        ]
        let rows = ScreenshotRows.rows(sessions: sessions, cases: [], lastUsed: "a")
        #expect(rows.map(\.id) == ["a", "b", "d"])
        #expect(rows.map(\.canSend) == [true, true, false])
        #expect(rows[0].name == "Alpha")
        #expect(ScreenshotRows.firstPick(rows) == "a")
        #expect(ScreenshotRows.badgeSubtitle(rows) == "Alpha")
        let noLast = ScreenshotRows.rows(sessions: sessions, cases: [], lastUsed: nil)
        #expect(noLast.map(\.id) == ["b", "a", "d"])
    }

    @Test func aLastUsedSessionThatCannotTypeIsNotPickedFirst() {
        let sessions = [session("a"), session("d", runtime: .codex, canNudge: false)]
        let rows = ScreenshotRows.rows(sessions: sessions, cases: [], lastUsed: "d")
        #expect(ScreenshotRows.firstPick(rows) == "a")
    }

    // MARK: Prompt

    @Test func promptFormat() {
        #expect(ScreenshotPrompt.text(note: "", paths: ["/tmp/a b.png"]) == "Screenshot: \"/tmp/a b.png\"")
        #expect(ScreenshotPrompt.text(note: "  Fix this  ", paths: ["/tmp/a.png"])
            == "Fix this\n\nScreenshot: \"/tmp/a.png\"")
        #expect(ScreenshotPrompt.text(note: "Compare", paths: ["/tmp/a.png", "/tmp/b.png"])
            == "Compare\n\nScreenshot: \"/tmp/a.png\"\nScreenshot: \"/tmp/b.png\"")
        let long = String(repeating: "x", count: 30_000)
        #expect(ScreenshotPrompt.text(note: long, paths: ["/tmp/a.png"]).count < 20_000)
    }

    // MARK: Panel states

    @Test func sendPostsOnePromptAndShowsSent() async {
        var sent: [(String, String)] = []
        let shot = ScreenCapture(url: URL(fileURLWithPath: "/tmp/a.png"), date: Date())
        let rows = ScreenshotRows.rows(sessions: [session("s1")], cases: [], lastUsed: nil)
        var remembered: String?
        let model = ScreenshotPanelModel(
            kind: .badge, captures: [shot], rows: rows,
            sendPrompt: { id, text in sent.append((id, text)); return SendPromptResult(sent: true) },
            remember: { remembered = $0 })
        model.note = "Look"
        await model.send()
        #expect(sent.count == 1)
        #expect(sent[0].1 == "Look\n\nScreenshot: \"/tmp/a.png\"")
        #expect(remembered == "s1")
        #expect(model.phase == .sent(name: "Alpha", working: false))
    }

    @Test func sessionClosedKeepsThePanelAndMarksTheRow() async {
        let model = panelModel { _ in SendPromptResult(sent: false, reason: .sessionClosed) }
        let first = model.pickedSession
        await model.send()
        #expect(model.phase == .editing)
        #expect(model.endedSessions == [first!])
        #expect(model.pickedSession != first)
        #expect(model.pickedSession != nil)
        model.pickSession(first!)
        #expect(model.pickedSession != first)
    }

    @Test func postFailedAndThrownErrorsShowTryAgain() async {
        let failed = panelModel { _ in SendPromptResult(sent: false, reason: .postFailed) }
        await failed.send()
        #expect(failed.phase == .failed)
        struct Boom: Error {}
        let thrown = panelModel { _ in throw Boom() }
        await thrown.send()
        #expect(thrown.phase == .failed)
    }

    @Test func shortcutPanelPicksNewestAndCountsInTheLabel() {
        let now = Date()
        let shots = (0..<3).map { ScreenCapture(url: URL(fileURLWithPath: "/tmp/\($0).png"), date: now.addingTimeInterval(Double(-$0) * 10)) }
        let rows = ScreenshotRows.rows(sessions: [session("s1")], cases: [], lastUsed: nil)
        let model = ScreenshotPanelModel(kind: .shortcut, captures: shots, rows: rows, sendPrompt: { _, _ in SendPromptResult(sent: true) })
        #expect(model.pickedCaptures.map(\.path) == ["/tmp/0.png"])
        #expect(model.sendLabel == "Send to Alpha")
        model.toggleShot(shots[1])
        #expect(model.sendLabel == "Send 2 to Alpha")
        #expect(model.promptText == "Screenshot: \"/tmp/0.png\"\nScreenshot: \"/tmp/1.png\"")
        model.toggleShot(shots[0])
        model.toggleShot(shots[1])
        #expect(!model.canSend)
    }

    @Test func aNonTypeableRowCannotBePicked() {
        let rows = ScreenshotRows.rows(sessions: [session("a"), session("d", runtime: .codex, canNudge: false)], cases: [], lastUsed: nil)
        let model = panelModel(rows: rows) { _ in SendPromptResult(sent: true) }
        model.pickSession("d")
        #expect(model.pickedSession == "a")
    }

    // MARK: Geometry and settings page

    @Test func badgeSitsTenPointsAboveTheThumbnailWithRightEdgesAligned() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = ScreenshotGeometry.badgeOrigin(screen: screen, size: CGSize(width: 180, height: 40))
        #expect(origin.x + 180 == 1440 - ScreenshotGeometry.thumbnailInset)
        #expect(origin.y == ScreenshotGeometry.thumbnailInset + ScreenshotGeometry.thumbnailHeight + 10)
        let top = ScreenshotGeometry.shortcutPanelOrigin(screen: screen, size: CGSize(width: 340, height: 200))
        #expect(top.x == 550)
        #expect(top.y > 450)
    }

    @Test func screenshotsHasItsOwnSettingsPage() {
        #expect(SettingsPage.allCases.contains(.screenshots))
        #expect(SettingsPage.initial(environment: ["KNOCK_SETTINGS_PAGE": "screenshots"]) == .screenshots)
        #expect(ScreenshotMode.allCases.map(\.title) == ["Off", "After every screenshot", "Only with a shortcut"])
    }
}
