import AppKit
import Combine
import Foundation

/// One thing the idea can be sent to besides a new session: a live session.
struct DocumentSendOption: Identifiable, Equatable {
    enum Target: Hashable { case session(String), newSession }
    let target: Target
    /// The project in plain words (same cleaning as the queue). The name in "Send to <name>".
    let name: String
    let isWorking: Bool
    /// "working now" or "idle".
    var statusWord: String { isWorking ? "working now" : "idle" }
    let folder: String?
    var id: Target { target }
}

/// State of the New idea page (WAG-255): the idea text, the attached files, the goal and the folder.
/// The launch itself is the shared `SessionLauncher`, so the split button's menu is the WAG-254 one.
@MainActor
final class NewIdeaModel: ObservableObject {
    static let folderKey = "NewIdeaFolder"

    @Published var idea = ""
    @Published var goal: DocumentGoal = .plan
    @Published private(set) var attachments: [URL] = []
    @Published private(set) var folder: URL
    @Published private(set) var busy = false
    @Published private(set) var errorText: String?
    /// Live sessions the idea can go to, and the pick. "New session" runs the launch target.
    @Published private(set) var sessionOptions: [DocumentSendOption] = []
    @Published private(set) var target: DocumentSendOption.Target = .newSession
    /// Bumped when a drop or a pick lands, so the view puts the cursor back in the idea box.
    @Published private(set) var focusTick = 0

    let launcher: SessionLauncher
    private var launcherChange: AnyCancellable?
    private let defaults: UserDefaults
    private let folderPicker: @MainActor (URL) -> URL?
    private let filePicker: @MainActor () -> [URL]
    private let sendPrompt: @Sendable (String, String) async throws -> SendPromptResult

    init(
        launcher: SessionLauncher = SessionLauncher(),
        defaults: UserDefaults = .standard,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        folderPicker: @escaping @MainActor (URL) -> URL? = NewIdeaModel.openFolderPanel,
        filePicker: @escaping @MainActor () -> [URL] = NewIdeaModel.openFilePanel,
        sendPrompt: @escaping @Sendable (String, String) async throws -> SendPromptResult = { _, _ in
            SendPromptResult(sent: false, reason: .notSupported)
        }
    ) {
        self.sendPrompt = sendPrompt
        self.launcher = launcher
        self.defaults = defaults
        self.folderPicker = folderPicker
        self.filePicker = filePicker
        self.folder = defaults.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0) } ?? homeDirectory
        launcherChange = launcher.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: Copy

    /// "Start planning" for the plan goal, else "Start".
    var startLabel: String {
        if case .session = target, let name = selectedSessionName { return "Send to \(name)" }
        return goal == .plan ? "Start planning" : "Start"
    }

    // MARK: Send to a running session

    /// Live Claude Code sessions that can receive a prompt. Codex, closed and no-nudge sessions
    /// are left out.
    static func sendableSessions(_ sessions: [SessionInfo]) -> [SessionInfo] {
        sessions.filter { $0.state == .live && $0.runtime == .claude && $0.canNudge }
    }

    static func sessionOptions(from sessions: [SessionInfo], cases: [Case], now: Date) -> [DocumentSendOption] {
        sendableSessions(sessions).map { session in
            let working = AgentStatus.isBusy(session, cases: cases) || session.context?.live?.phase == "working"
            return DocumentSendOption(
                target: .session(session.id),
                name: ProjectName.display(project: session.project),
                isWorking: working,
                folder: session.cwd.isEmpty ? nil : session.cwd)
        }
    }

    /// Refreshes the list. A pick whose session went away falls back to a new session.
    func updateSessions(_ sessions: [SessionInfo], cases: [Case], now: Date = Date()) {
        let options = Self.sessionOptions(from: sessions, cases: cases, now: now)
        if options != sessionOptions { sessionOptions = options }
        if case .session = target, !options.contains(where: { $0.target == target }) { target = .newSession }
    }

    var selectedSessionName: String? {
        guard case .session = target else { return nil }
        return sessionOptions.first { $0.target == target }?.name
    }

    func chooseSession(_ target: DocumentSendOption.Target) { self.target = target }
    func chooseNewSession() { target = .newSession }

    // MARK: Agent chip (WAG-274)

    /// The chip's words: "Claude Code · Claude app", or "<project> · Running session" for a live session.
    var chipLabel: String {
        if let name = selectedSessionName { return "\(name) · Running session" }
        return launcher.launchTarget.chipLabel
    }

    /// True when this run goes somewhere other than the saved default: the chip turns honey.
    var chipDiffersFromDefault: Bool {
        if case .session = target { return true }
        return launcher.differsFromDefault
    }

    /// A running session cannot be the default, so the checkbox only works for a launch target.
    var canUseAsDefault: Bool { target == .newSession }

    /// "Use as my default" is ticked when this run's pick is the saved default.
    var pickIsDefault: Bool { target == .newSession && !launcher.differsFromDefault }

    func useAsDefault() {
        guard canUseAsDefault else { return }
        launcher.useCurrentAsDefault()
    }

    static func failureText(_ reason: SendPromptFailureReason?) -> String {
        switch reason {
        case .sessionClosed: return "That session has closed. Pick another one, or start a new session."
        case .notSupported: return "That session cannot take a prompt from Waggle. Start a new session instead."
        case .postFailed, .none: return "The prompt did not arrive. Try again, or start a new session."
        }
    }

    /// The folder's own name, as the person knows it ("Desktop"), not its path.
    var folderName: String {
        let name = folder.lastPathComponent
        return name.isEmpty ? folder.path : name
    }

    // MARK: Prompt

    var prompt: String {
        DocumentPrompt.build(idea: idea, paths: attachments.map(\.path), goal: goal)
    }

    /// A start needs something to work from: a few words or a file.
    var canStart: Bool {
        !idea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    // MARK: Attachments

    /// Any type; a PRD is just a file. The same file twice is one chip.
    func addFiles(_ urls: [URL]) {
        for url in urls where url.isFileURL && !attachments.contains(where: { $0.path == url.path }) {
            attachments.append(url)
        }
    }

    func removeAttachment(_ url: URL) { attachments.removeAll { $0 == url } }

    func pickFiles() { addFiles(filePicker()) }

    /// The real picker. No test reaches it.
    static func openFilePanel() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Add notes, screenshots or a PRD"
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// A file dropped on the window (or picked from File): attach it, open its folder, and ask the view
    /// to focus the idea box. The folder is not saved as the default.
    func receive(files urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard let first = files.first else { return }
        addFiles(files)
        folder = first.deletingLastPathComponent()
        target = .newSession
        focusTick += 1
        refreshForFolder()
    }

    /// Adds every file of a drop. A provider that holds no file is skipped.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier("public.file-url") }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else { url = item as? URL }
                guard let url else { return }
                Task { @MainActor [weak self] in self?.addFiles([url]) }
            }
        }
        return true
    }

    // MARK: Folder

    func chooseFolder(_ url: URL) {
        folder = url
        target = .newSession
        defaults.set(url.path, forKey: Self.folderKey)
        refreshForFolder()
    }

    /// The Superset check for the current folder. `settled()` waits for the last one.
    private var folderRefresh: Task<Void, Never>?

    private func refreshForFolder() {
        let folder = folder
        folderRefresh = Task { await launcher.refreshSupersetAvailability(folder: folder) }
    }

    func settled() async { await folderRefresh?.value }

    func pickFolder() {
        if let url = folderPicker(folder) { chooseFolder(url) }
    }

    /// The real picker. No test reaches it.
    static func openFolderPanel(startingAt folder: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: Start

    /// Checks the CLIs and the apps on this Mac. Call once when the page appears.
    func loadAvailability() async { await launcher.loadAvailability(folder: folder) }

    /// The workspace name for Superset and T3 Code: the idea's first line, else the first file's name.
    var topic: String {
        let firstLine = idea.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return firstLine ?? attachments.first?.deletingPathExtension().lastPathComponent ?? ""
    }

    /// Starts the session. The box clears once the prompt left.
    func start() async {
        guard canStart, !busy else { return }
        busy = true
        errorText = nil
        defer { busy = false }
        let finished: Bool
        switch target {
        case .session(let sessionId):
            do {
                let result = try await sendPrompt(sessionId, prompt)
                finished = result.sent
                errorText = result.sent ? nil : Self.failureText(result.reason)
            } catch {
                finished = false
                errorText = Self.failureText(.postFailed)
            }
        case .newSession:
            finished = await launcher.start(prompt: prompt, folder: folder, topic: topic)
            errorText = launcher.errorText
        }
        if finished {
            let targetName: String = if case .session = target { "session" } else { launcher.launchTarget.rawValue }
            UsageReporter.current?.record(.newIdeaStarted, variantName: targetName, n: attachments.count)
            idea = ""
            attachments = []
            // The next idea starts from the saved default again.
            launcher.resetToDefault()
            target = .newSession
        }
    }
}
