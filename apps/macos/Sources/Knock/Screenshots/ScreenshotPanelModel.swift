import Combine
import Foundation

/// The state of the Send panel and the Shortcut panel (WAG-402). Both panels share it: the badge opens it with one
/// screenshot, the shortcut with the 3 latest.
@MainActor
final class ScreenshotPanelModel: ObservableObject {
    enum Kind: Equatable { case badge, shortcut, snip }

    enum Phase: Equatable {
        case editing
        case sending
        case sent(name: String, working: Bool)
        /// A new session started in this folder (WAG-404).
        case started(folder: String)
        /// The send failed for a reason other than a closed session. "Try again" shows.
        case failed
    }

    let kind: Kind
    let captures: [ScreenCapture]
    @Published private(set) var rows: [ScreenshotSessionRow]
    @Published private(set) var pickedSession: String?
    @Published private(set) var pickedShots: Set<URL>
    @Published var note = ""
    @Published private(set) var phase: Phase = .editing
    /// Rows whose session ended since the list loaded. They show the line and cannot be picked.
    @Published private(set) var endedSessions: Set<String> = []
    @Published private(set) var copiedRow: String?

    /// WAG-404: the box the operator drew. Set for the snip panel only.
    let snip: SnipInfo?
    let newSession: NewSessionConfig?
    @Published private(set) var newSessionPicked = false
    @Published private(set) var folders: [FolderChoice]
    @Published private(set) var pickedFolder: URL

    private let sendPrompt: (String, String) async throws -> SendPromptResult
    private let remember: (String) -> Void
    private let copy: (String) -> Void
    private let finish: () -> Void

    init(
        kind: Kind, captures: [ScreenCapture], rows: [ScreenshotSessionRow],
        sendPrompt: @escaping (String, String) async throws -> SendPromptResult,
        remember: @escaping (String) -> Void = { _ in },
        copy: @escaping (String) -> Void = { _ in },
        finish: @escaping () -> Void = {},
        snip: SnipInfo? = nil,
        newSession: NewSessionConfig? = nil
    ) {
        self.snip = snip
        self.newSession = newSession
        folders = newSession?.folders ?? []
        pickedFolder = newSession?.defaultFolder ?? FileManager.default.homeDirectoryForCurrentUser
        self.kind = kind
        self.captures = captures
        self.rows = rows
        self.sendPrompt = sendPrompt
        self.remember = remember
        self.copy = copy
        self.finish = finish
        // The newest screenshot is picked first.
        pickedShots = Set(captures.sorted { $0.date > $1.date }.prefix(1).map(\.url))
        pickedSession = ScreenshotRows.firstPick(rows)
        // With no live session that can take a message, New session is picked first.
        newSessionPicked = newSession != nil && pickedSession == nil
    }

    var pickedCaptures: [ScreenCapture] { captures.filter { pickedShots.contains($0.url) } }
    var pickedRow: ScreenshotSessionRow? { rows.first { $0.id == pickedSession } }
    var pickedFolderName: String { FolderChoice(url: pickedFolder).name }
    var sendLabel: String {
        newSessionPicked ? ScreenshotCopy.startIn(pickedFolderName)
            : ScreenshotCopy.sendLabel(name: pickedRow?.name, count: pickedShots.count)
    }
    var hasTarget: Bool { newSessionPicked || pickedRow != nil }
    var canSend: Bool { phase == .editing && hasTarget && !pickedShots.isEmpty }

    func pickNewSession() {
        guard newSession != nil, phase == .editing || phase == .failed else { return }
        newSessionPicked = true
        if phase == .failed { phase = .editing }
    }

    func pickFolder(_ folder: FolderChoice) {
        pickedFolder = folder.url
        pickNewSession()
    }

    /// "Other folder...": the operator's pick joins the top of the list.
    func chooseOtherFolder() {
        guard let url = newSession?.chooseOther(pickedFolder) else { return }
        let choice = FolderChoice(url: url)
        if !folders.contains(choice) { folders.insert(choice, at: 0) }
        pickFolder(choice)
    }

    func pickSession(_ id: String) {
        guard phase == .editing || phase == .failed,
              let row = rows.first(where: { $0.id == id }), row.canSend, !endedSessions.contains(id) else { return }
        pickedSession = id
        newSessionPicked = false
        if phase == .failed { phase = .editing }
    }

    func toggleShot(_ capture: ScreenCapture) {
        if pickedShots.contains(capture.url) { pickedShots.remove(capture.url) } else { pickedShots.insert(capture.url) }
    }

    /// The text a send would post for the screenshots picked now.
    var promptText: String {
        ScreenshotPrompt.text(note: note, paths: pickedCaptures.map(\.path))
    }

    /// The workspace name for a new session: the first line of the note, else a plain word.
    var topic: String {
        let first = note.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if first.isEmpty { return snip != nil ? "Snip" : "Screenshot" }
        return String(first.prefix(60))
    }

    func copyPath(row: ScreenshotSessionRow) {
        copy(ScreenshotPrompt.text(note: "", paths: pickedCaptures.map(\.path)))
        copiedRow = row.id
    }

    func send() async {
        guard canSend || phase == .failed, hasTarget, !pickedShots.isEmpty else { return }
        if newSessionPicked, let newSession {
            phase = .sending
            let folder = pickedFolder
            if await newSession.start(promptText, folder, topic) {
                phase = .started(folder: pickedFolderName)
                finish()
            } else {
                phase = .failed
            }
            return
        }
        guard let row = pickedRow else { return }
        phase = .sending
        let result: SendPromptResult
        do {
            result = try await sendPrompt(row.id, promptText)
        } catch {
            phase = .failed
            return
        }
        if result.sent {
            remember(row.id)
            phase = .sent(name: row.name, working: row.dot == .working)
            finish()
        } else if result.reason == .sessionClosed {
            endedSessions.insert(row.id)
            pickedSession = rows.first { $0.canSend && !endedSessions.contains($0.id) }?.id
            phase = .editing
        } else {
            phase = .failed
        }
    }
}
