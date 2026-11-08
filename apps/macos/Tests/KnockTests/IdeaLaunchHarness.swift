import AppKit
import Foundation
@testable import Knock

/// WAG-271: the launch tests drive the New idea page's model, as the Start button does. The harness
/// builds it the way a file drop does (one attached file, its folder), so a Start has something to send.
/// It uses its own `UserDefaults` suite, so no test touches the real folder or launch pick.
@MainActor
final class IdeaLaunchHarness {
    let model: NewIdeaModel
    let launcher: SessionLauncher
    private let suite: String
    /// Called once the prompt left (the idea box cleared).
    var onFinish: () -> Void = {}

    init(
        fileURL: URL,
        sessions: [SessionInfo] = [],
        cases: [Case] = [],
        now: Date = Date(),
        sendPrompt: @escaping @Sendable (String, String) async throws -> SendPromptResult,
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
        clock: @escaping @Sendable () -> Date = { Date() },
        folderPicker: @escaping @MainActor (URL) -> URL? = { _ in nil }
    ) {
        suite = "knock-test-idea-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        launcher = SessionLauncher(
            launcher: terminal, resolvePath: resolvePath, pasteboard: pasteboard, fileManager: fileManager,
            opener: opener, launchTargetStore: launchTargetStore, sleep: sleep, cliRunner: cliRunner,
            homeDirectory: homeDirectory, t3Secrets: t3Secrets, t3Meta: t3Meta, t3Server: t3Server,
            environment: environment, isProcessAlive: isProcessAlive, clock: clock)
        model = NewIdeaModel(
            launcher: launcher, defaults: defaults, homeDirectory: URL(fileURLWithPath: "/tmp"),
            folderPicker: folderPicker, filePicker: { [] }, sendPrompt: sendPrompt)
        model.updateSessions(sessions, cases: cases, now: now)
        model.receive(files: [fileURL])
    }

    deinit { UserDefaults.standard.removePersistentDomain(forName: suite) }

    var folder: URL {
        get { model.folder }
        set { model.chooseFolder(newValue) }
    }
    /// The prompt as sent: the box clears once it left, so the last start keeps it.
    private var sentPrompt: String?
    var prompt: String { sentPrompt ?? model.prompt }
    var errorText: String? { model.errorText }
    var launchTarget: LaunchTarget { launcher.launchTarget }
    var availability: LaunchAvailability { launcher.availability }
    func loadAvailability() async {
        await model.settled()
        await model.loadAvailability()
    }
    func chooseLaunchTarget(_ target: LaunchTarget) { launcher.chooseLaunchTarget(target) }

    /// Starts, and calls `onFinish` when the prompt left.
    func submit() async {
        sentPrompt = model.prompt
        await model.start()
        if model.idea.isEmpty && model.attachments.isEmpty { onFinish() }
    }
}
