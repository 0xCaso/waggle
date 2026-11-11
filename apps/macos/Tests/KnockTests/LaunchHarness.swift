import AppKit
import Foundation
@testable import Knock

/// Drives the shared `SessionLauncher` the way a start from setup does: one prompt, one folder, one
/// topic. The harness builds a prompt from the idea text and the attached file (if any), so a start
/// has something to send. The launch pick comes from the fake store each test passes in.
@MainActor
final class LaunchHarness {
    let launcher: SessionLauncher
    private let attachments: [URL]
    private var folderRefresh: Task<Void, Never>?
    /// The text the prompt starts from. Cleared once the prompt left.
    var idea = ""
    private(set) var errorText: String?
    /// Called once the prompt left.
    var onFinish: () -> Void = {}

    init(
        fileURL: URL?,
        folder: URL? = nil,
        launcher terminal: TerminalLaunching,
        resolvePath: @escaping @Sendable () async -> LoginShellPathResolution = { await LoginShellPath.resolve() },
        pasteboard: NSPasteboard = .general,
        fileManager: FileManager = .default,
        opener: ExternalAppOpening,
        launchTargetStore: LaunchTargetStoring,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { _ in },
        cliRunner: CLIRunning = ProcessCLIRunner(),
        homeDirectory: String = NSHomeDirectory(),
        t3Secrets: SecretStoring = KeychainSecretStore(),
        t3Meta: T3MetaStoring = UserDefaultsT3Meta(),
        t3Server: T3Serving = T3HTTPServer(),
        environment: [String: String] = [:],
        isProcessAlive: @escaping @Sendable (Int) -> Bool = { _ in true },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        launcher = SessionLauncher(
            launcher: terminal, resolvePath: resolvePath, pasteboard: pasteboard, fileManager: fileManager,
            opener: opener, launchTargetStore: launchTargetStore, sleep: sleep, cliRunner: cliRunner,
            homeDirectory: homeDirectory, t3Secrets: t3Secrets, t3Meta: t3Meta, t3Server: t3Server,
            environment: environment, isProcessAlive: isProcessAlive, clock: clock)
        attachments = fileURL.map { [$0] } ?? []
        self.folderURL = folder ?? fileURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/tmp")
        refreshForFolder()
    }

    private var folderURL: URL
    var folder: URL {
        get { folderURL }
        set {
            folderURL = newValue
            refreshForFolder()
        }
    }

    /// The Superset check for the current folder. `settled()` waits for the last one.
    private func refreshForFolder() {
        let folder = folderURL
        folderRefresh = Task { [launcher] in await launcher.refreshSupersetAvailability(folder: folder) }
    }

    /// The workspace name for Superset and T3 Code: the idea's first line, else the first file's name.
    private var topic: String {
        let firstLine = idea.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return firstLine ?? attachments.first?.deletingPathExtension().lastPathComponent ?? ""
    }

    /// The prompt as sent: the idea clears once it left, so the last start keeps it.
    private var sentPrompt: String?
    var prompt: String {
        sentPrompt ?? DocumentPrompt.build(idea: idea, paths: attachments.map(\.path), goal: .plan)
    }
    var launchTarget: LaunchTarget { launcher.launchTarget }
    var availability: LaunchAvailability { launcher.availability }
    func loadAvailability() async {
        await folderRefresh?.value
        await launcher.loadAvailability(folder: folderURL)
    }
    func chooseLaunchTarget(_ target: LaunchTarget) { launcher.chooseLaunchTarget(target) }

    /// Starts, and calls `onFinish` when the prompt left.
    func submit() async {
        guard !idea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        let text = DocumentPrompt.build(idea: idea, paths: attachments.map(\.path), goal: .plan)
        let finished = await launcher.start(prompt: text, folder: folderURL, topic: topic)
        errorText = launcher.errorText
        if finished {
            sentPrompt = text
            idea = ""
            launcher.resetToDefault()
            onFinish()
        }
    }
}
