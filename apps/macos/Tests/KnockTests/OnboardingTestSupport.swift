import Foundation
@testable import Knock

/// A throwaway, never-reachable `KnockClient` for tests that do not talk to a daemon: `startDaemon: {}` is a
/// hard no-op, so a socket path nothing listens on can never start a real `waggle daemon` (AGENTS.md: never
/// touch the real install from a test).
@MainActor
func makeUnreachableClient() -> KnockClient {
    KnockClient(socketPath: makeTempSocketPath(), backoffSchedule: [0.02, 0.02, 0.05], startDaemon: {})
}

/// A getting started model on a temp file, never the real `KNOCK_HOME`. `isOnboarded` stands for the old
/// `onboarded` marker: true makes the first load a migrated one.
@MainActor
func makeTempGettingStarted(
    isOnboarded: Bool = false, now: Date = Date(timeIntervalSince1970: 1_800_000_000), tour: CoachMarkTourModel = CoachMarkTourModel()
) -> (model: GettingStartedModel, root: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("waggle-gs-\(UUID().uuidString)")
    let env = ["KNOCK_HOME": root.path]
    let store = GettingStartedStore(environment: env, isOnboarded: { isOnboarded }, now: { now })
    return (GettingStartedModel(store: store, tour: tour), root)
}

/// What a test sends and starts: nothing real. Every effect is recorded.
@MainActor
final class OnboardingFakes {
    var prompts: [(sessionId: String, text: String)] = []
    var promptResult = SendPromptResult(sent: true)
    var terminalStarts: [(prompt: String, folder: URL, topic: String)] = []
    var terminalFailure: String?
    var copied: [String] = []
    var pickedFolder: URL?
    var onboardedCalls = 0
    var firstJobStarted = 0
    var sessions: [SessionInfo] = []
    var cases: [Case] = []
    var isOnboarded = false
}

/// A model with every outside effect faked: no daemon, no Terminal, no real session, no clipboard.
@MainActor
func makeOnboardingModel(
    runner: OnboardingCommandRunning = FakeCommandRunner(),
    fakes: OnboardingFakes = OnboardingFakes(),
    askPreferences: AskPreferencesModel? = nil,
    gettingStarted: GettingStartedModel? = nil,
    claudeApp: ClaudeAppModel? = nil,
    resolvedKnockBinaryPath: @escaping () -> String? = { nil },
    now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }
) -> OnboardingModel {
    OnboardingModel(
        runner: runner,
        askPreferences: askPreferences ?? AskPreferencesModel(client: makeUnreachableClient()),
        gettingStarted: gettingStarted ?? makeTempGettingStarted().model,
        loadSessions: { fakes.sessions },
        loadCases: { fakes.cases },
        sendPrompt: { id, text in
            fakes.prompts.append((id, text))
            return fakes.promptResult
        },
        startInTerminal: { prompt, folder, topic in
            fakes.terminalStarts.append((prompt, folder, topic))
            return fakes.terminalFailure
        },
        copyToPasteboard: { fakes.copied.append($0) },
        pickFolder: { fakes.pickedFolder },
        markOnboarded: { fakes.onboardedCalls += 1 },
        isOnboarded: { fakes.isOnboarded },
        onFirstJobStarted: { fakes.firstJobStarted += 1 },
        resolvedKnockBinaryPath: resolvedKnockBinaryPath,
        claudeApp: claudeApp ?? makeTempClaudeAppModel().model,
        now: now)
}
