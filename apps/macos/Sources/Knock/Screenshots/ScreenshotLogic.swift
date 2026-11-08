import Foundation
import ImageIO

/// WAG-402: send a screenshot the operator took to a live agent session. The words and rules, pure so they are
/// unit-tested. Plain copy, no em-dashes.
enum ScreenshotMode: String, CaseIterable, Identifiable, Equatable, Sendable {
    case off
    case everyShot
    case shortcut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .everyShot: "After every screenshot"
        case .shortcut: "Only with a shortcut"
        }
    }

    var subtitle: String? {
        switch self {
        case .off: nil
        case .everyShot: "A small badge opens the panel"
        case .shortcut: "Control Option S, or the menu bar"
        }
    }

    var isOn: Bool { self != .off }
}

/// The mode and the last used session, in the app's `UserDefaults` store like the other add-on settings.
enum ScreenshotSettings {
    private static let modeKey = "screenshotSendMode"
    private static let lastSessionKey = "screenshotLastSession"

    /// Off by default. An unknown stored value reads as Off.
    static func mode(defaults: UserDefaults = .standard) -> ScreenshotMode {
        defaults.string(forKey: modeKey).flatMap(ScreenshotMode.init(rawValue:)) ?? .off
    }

    static func setMode(_ mode: ScreenshotMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: modeKey)
        NotificationCenter.default.post(name: .knockScreenshotModeChanged, object: nil)
    }

    private static let snipKey = "screenshotSnipAreaOn"

    /// WAG-404: Snip an area. Off by default. It sits next to the mode and posts the same change note.
    static func snipIsOn(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: snipKey)
    }

    static func setSnip(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: snipKey)
        NotificationCenter.default.post(name: .knockScreenshotModeChanged, object: nil)
    }

    static func lastSession(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: lastSessionKey)
    }

    static func setLastSession(_ id: String, defaults: UserDefaults = .standard) {
        defaults.set(id, forKey: lastSessionKey)
    }
}

extension Notification.Name {
    static let knockScreenshotModeChanged = Notification.Name("knockScreenshotModeChanged")
}

enum ScreenshotCopy {
    static let settingsTitle = "Send screenshots to a session"
    static let settingsSub = "Waggle only looks at screenshots you take, never at your screen."
    static let thumbnailTip = "For the badge to show at once, turn off Show Floating Thumbnail (Command Shift 5 \u{203A} Options)."
    static let badgeTitle = "Send to an agent"
    static let turnOff = "Turn off"
    static let sendHead = "Send this screenshot?"
    static let justNow = "Just now"
    static let sendTo = "SEND TO"
    static let notNow = "Not now"
    static let copyPath = "Copy path"
    static let copied = "Copied"
    static let notTypeable = "Waggle cannot type into this one"
    static let shortcutHead = "Send a screenshot"
    static let shortcutMeta = "Your 3 latest \u{00B7} pick one or more"
    static let menuItem = "Send a screenshot"
    static let notePlaceholder = "Add a note (optional)"
    static let sessionEnded = "This session ended. Pick another one."
    static let couldNotSend = "Couldn't send. Try again."
    static let tryAgain = "Try again"
    static let noScreenshots = "No screenshots yet. Take one, then press the shortcut again."
    static let snipTitle = "Snip an area"
    static let snipSub = "Control Shift W opens the crosshair. Waggle sees only the box you draw."
    static let snipOnSub = "Control Shift W, or the menu bar"
    static let snipMenuItem = "Snip an area"
    static let snipHead = "Send this area"
    static let snipNotePlaceholder = "What should the agent do with this?"
    static let cancel = "Cancel"
    static let snipFailed = "Couldn't snip. Check Screen Recording for Waggle in System Settings."
    static let snipNeedsAccess = "To snip, allow Screen Recording for Waggle in System Settings, then press Control Shift W again."
    static let newSession = "New session"
    static let otherFolder = "Other folder\u{2026}"
    static let snipKeyChip = "\u{2303}\u{21E7}W"
    static let workingSub = "It's working now, so it reads it after this turn."

    static func sent(to name: String) -> String { "Sent to \(name)" }
    static func started(in folder: String) -> String { "Started in \(folder)" }
    static func startIn(_ folder: String) -> String { "Start in \(folder)" }

    /// "<w> \u{00D7} <h> \u{00B7} from <app>". The app part is left out when Waggle did not see the front app.
    static func snipMeta(width: Int, height: Int, app: String?) -> String {
        let size = "\(width) \u{00D7} \(height)"
        guard let app, !app.isEmpty else { return size }
        return "\(size) \u{00B7} from \(app)"
    }

    static func sendLabel(name: String?, count: Int) -> String {
        guard let name else { return "Send" }
        return count > 1 ? "Send \(count) to \(name)" : "Send to \(name)"
    }
}

/// A screenshot file macOS marked as a screen capture.
struct ScreenCapture: Equatable, Hashable, Identifiable, Sendable {
    let url: URL
    let date: Date
    var id: URL { url }
    var path: String { url.path }
}

/// What a session row in the panel shows.
struct ScreenshotSessionRow: Equatable, Identifiable {
    enum Dot: Equatable { case working, waiting, idle }

    let id: String
    let name: String
    let dot: Dot
    let stateLine: String
    /// False for a session Waggle cannot type into. It shows "Copy path" instead of being pickable.
    let canSend: Bool
    /// Project and folder, for example "waggle · Rumbling tray" (WAG-406). Empty when the daemon sends no folder.
    var place: String = ""
    /// Claude Code, Codex or a desktop app (WAG-406).
    var agent: String = ""
    /// The full folder path, for the hover tooltip only.
    var path: String = ""

    /// The agent, then the state: "Claude Code · Working".
    var detailLine: String { agent.isEmpty || agent == name ? stateLine : "\(agent) \u{00B7} \(stateLine)" }
}

enum ScreenshotRows {
    /// A session Waggle can type into is a live Claude Code session that takes a nudge. This is the same rule as
    /// "Send to a running session" in Start from a document.
    static func canType(_ session: SessionInfo) -> Bool {
        session.state == .live && session.runtime == .claude && session.canNudge
    }

    /// Live sessions only. The last used one first, then the ones Waggle can type into, then the rest. Newest first
    /// inside each group.
    static func rows(sessions: [SessionInfo], cases: [Case], lastUsed: String?) -> [ScreenshotSessionRow] {
        let live = sessions.filter { $0.state == .live }
        func rank(_ s: SessionInfo) -> Int {
            if s.id == lastUsed && canType(s) { return 0 }
            return canType(s) ? 1 : 2
        }
        let sorted = live.enumerated().sorted { a, b in
            if rank(a.element) != rank(b.element) { return rank(a.element) < rank(b.element) }
            if a.element.connectedAt != b.element.connectedAt { return a.element.connectedAt > b.element.connectedAt }
            return a.offset < b.offset
        }
        return sorted.map { row(for: $0.element, cases: cases) }
    }

    static func row(for session: SessionInfo, cases: [Case]) -> ScreenshotSessionRow {
        let status = AgentStatus.forSession(session, cases: cases)
        let dot: ScreenshotSessionRow.Dot
        let line: String
        switch status {
        case .needsYou: dot = .waiting; line = "Waiting for you"
        case .working, .writingToYou: dot = .working; line = "Working"
        case .waitingForPickup: dot = .working; line = "Waiting for the agent"
        case .connected, .closed: dot = .idle; line = "Idle"
        }
        let canSend = canType(session)
        return ScreenshotSessionRow(
            id: session.id, name: SessionTitle.pick(session) ?? ProjectName.display(project: session.project), dot: dot,
            stateLine: canSend ? line : ScreenshotCopy.notTypeable, canSend: canSend,
            place: place(cwd: session.cwd, project: session.project),
            agent: session.runtimeLabel,
            path: session.cwd)
    }

    /// "waggle · Rumbling tray" for a worktree (".../worktrees/<project>/<folder>"), else the folder name. Reads the
    /// path only, never the folder itself.
    static func place(cwd: String, project: String) -> String {
        let parts = cwd.split(separator: "/").map(String.init)
        if let i = parts.lastIndex(of: "worktrees"), i + 2 < parts.count {
            return "\(parts[i + 1]) \u{00B7} \(ProjectName.readable(folder: parts[i + 2]))"
        }
        guard let last = parts.last, cwd != "/" else { return "" }
        return last
    }

    /// The row to pick first: the last used one when it can take a message, else the first one that can.
    static func firstPick(_ rows: [ScreenshotSessionRow]) -> String? {
        rows.first(where: \.canSend)?.id
    }

    /// The line under "Send to an agent" on the badge: the name of the session the panel picks first.
    static func badgeSubtitle(_ rows: [ScreenshotSessionRow]) -> String? {
        firstPick(rows).flatMap { id in rows.first { $0.id == id }?.name }
    }
}

enum ScreenshotPrompt {
    /// The daemon takes up to 20,000 characters (daemon/src/protocol/rpc.ts). The note is cut well below that.
    static let maxNoteLength = 10_000

    /// The note (if any), then one line per screenshot: `Screenshot: "<absolute path>"`.
    static func text(note: String, paths: [String]) -> String {
        let lines = paths.map { "Screenshot: \"\($0)\"" }.joined(separator: "\n")
        var clean = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.count > maxNoteLength { clean = String(clean.prefix(maxNoteLength)) }
        return clean.isEmpty ? lines : clean + "\n\n" + lines
    }
}

/// Where the badge and the panels sit. Pure, so the numbers are tested.
enum ScreenshotGeometry {
    /// macOS shows its thumbnail 10 pt from the right and bottom edges of the screen. Its size follows the picture;
    /// this is the height of a typical one. The system does not say where it is, so the badge assumes it.
    static let thumbnailInset: CGFloat = 10
    static let thumbnailHeight: CGFloat = 112
    static let badgeGap: CGFloat = 10
    static let panelWidth: CGFloat = 340

    /// Right edge on the thumbnail's right edge, 10 pt above the thumbnail's top.
    static func badgeOrigin(screen: CGRect, size: CGSize) -> CGPoint {
        CGPoint(
            x: screen.maxX - thumbnailInset - size.width,
            y: screen.minY + thumbnailInset + thumbnailHeight + badgeGap)
    }

    /// The send panel opens in the same corner, on top of where the badge was.
    static func cornerPanelOrigin(screen: CGRect, size: CGSize) -> CGPoint {
        CGPoint(x: screen.maxX - thumbnailInset - size.width, y: screen.minY + thumbnailInset + thumbnailHeight + badgeGap)
    }

    /// Centered, near the top of the screen.
    /// WAG-404: beside the box, to its right, or to its left when the right side has no room. Always inside the
    /// screen. `size` includes the 20 pt shadow margin the view adds on every side.
    static func snipPanelOrigin(box: CGRect, screen: CGRect, size: CGSize) -> CGPoint {
        let margin: CGFloat = 20, gap: CGFloat = 12, edge: CGFloat = 8
        var x = box.maxX + gap - margin
        if x + size.width - margin > screen.maxX - edge { x = box.minX - gap - size.width + margin }
        x = min(max(x, screen.minX + edge - margin), screen.maxX - edge - size.width + margin)
        var y = box.maxY - size.height + margin
        y = min(max(y, screen.minY + edge - margin), screen.maxY - edge - size.height + margin)
        return CGPoint(x: x, y: y)
    }

    static func shortcutPanelOrigin(screen: CGRect, size: CGSize) -> CGPoint {
        CGPoint(x: screen.midX - size.width / 2, y: screen.maxY - size.height - screen.height * 0.12)
    }
}

// MARK: - WAG-404: snip an area

/// What the snip panel shows about the box the operator drew.
struct SnipInfo: Equatable {
    let width: Int
    let height: Int
    let app: String?
    var meta: String { ScreenshotCopy.snipMeta(width: width, height: height, app: app) }
}

enum AreaCaptureOutcome: Equatable {
    /// Esc, or an empty or missing file. Nothing shows.
    case cancelled
    /// The capture tool failed to run. One plain line shows.
    case failed
    case captured(URL)
}

/// The crosshair. The real one runs `screencapture -i -x`; tests use a fake that writes a fixture PNG.
protocol AreaCapturing: Sendable {
    func capture(to file: URL) async -> AreaCaptureOutcome
}

struct ScreencaptureAreaCapturer: AreaCapturing {
    static let tool = "/usr/sbin/screencapture"

    func capture(to file: URL) async -> AreaCaptureOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: Self.tool)
                process.arguments = ["-i", "-x", file.path]
                process.standardError = Pipe()
                do { try process.run() } catch {
                    continuation.resume(returning: .failed)
                    return
                }
                process.waitUntilExit()
                // Esc ends with status 0 and no file. Any other status is a failure.
                continuation.resume(returning: Self.outcome(status: process.terminationStatus, file: file))
            }
        }
    }

    static func outcome(status: Int32, file: URL, fileManager: FileManager = .default) -> AreaCaptureOutcome {
        guard status == 0 else { return .failed }
        let size = (try? fileManager.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        return size > 0 ? .captured(file) : .cancelled
    }
}

/// The "Snips" folder in the app data folder (it follows `KNOCK_HOME`). It keeps the newest 50 files.
enum SnipFiles {
    static let keep = 50

    static func folder(root: String = KnockClient.defaultDataRoot()) -> URL {
        URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("Snips", isDirectory: true)
    }

    static func newFile(in folder: URL, now: Date = Date()) -> URL {
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        return folder.appendingPathComponent("Snip \(f.string(from: now)).png")
    }

    /// Deletes the PNG files past the newest `keep`. Other files stay.
    static func prune(in folder: URL, keep: Int = SnipFiles.keep, fileManager: FileManager = .default) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        let snips = files.filter { $0.pathExtension.lowercased() == "png" }.map { url -> (URL, Date) in
            (url, (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast)
        }
        for (url, _) in snips.sorted(by: { $0.1 > $1.1 }).dropFirst(keep) {
            try? fileManager.removeItem(at: url)
        }
    }

    /// The size in pixels, read from the file header only.
    static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }
}

// MARK: - WAG-404: the New session row

struct FolderChoice: Equatable, Identifiable, Hashable {
    let url: URL
    var id: String { url.path }
    /// The folder's own name, as the person knows it, never its path.
    var name: String {
        let last = url.lastPathComponent
        return last.isEmpty ? url.path : last
    }
}

@MainActor
enum NewSessionFolders {
    /// The chip menu: folders of the live sessions (newest first, no duplicates), then the New idea saved folder.
    /// "Other folder..." is added by the view.
    static func choices(sessions: [SessionInfo], saved: URL) -> [FolderChoice] {
        var seen = Set<String>()
        var out: [FolderChoice] = []
        func add(path: String) {
            let key = URL(fileURLWithPath: path).standardizedFileURL.path
            if seen.insert(key).inserted { out.append(FolderChoice(url: URL(fileURLWithPath: key, isDirectory: true))) }
        }
        let live = sessions.filter { $0.state == .live && !$0.cwd.isEmpty }
        for s in live.enumerated().sorted(by: { a, b in
            a.element.connectedAt != b.element.connectedAt ? a.element.connectedAt > b.element.connectedAt : a.offset < b.offset
        }) { add(path: s.element.cwd) }
        add(path: saved.path)
        return out
    }

    /// The New idea saved folder, else the home folder (the same default as the New idea page).
    static func savedFolder(defaults: UserDefaults = .standard, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        defaults.string(forKey: NewIdeaModel.folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home
    }

    /// "Claude Code in Terminal". Conductor has no agent line, so it reads "Conductor".
    static func launchTargetName(_ target: LaunchTarget) -> String {
        target == .conductor ? "Conductor" : "\(target.agentName) \(target.whereLabel)"
    }
}

/// What the panel needs to start a session. A fake stands in for it in tests.
@MainActor
protocol SessionStarting {
    func start(prompt text: String, folder: URL, topic: String) async -> Bool
}

extension SessionLauncher: SessionStarting {}

struct NewSessionConfig {
    var subtitle: String
    var folders: [FolderChoice]
    var defaultFolder: URL
    var start: @MainActor (String, URL, String) async -> Bool
    var chooseOther: @MainActor (URL) -> URL?
}
