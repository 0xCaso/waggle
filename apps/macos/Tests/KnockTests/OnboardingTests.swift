import Testing
import Foundation
@testable import Knock

struct DoctorLineParserTests {
    @Test func parsesAnOkLine() {
        let check = DoctorLineParser.parse("ok    service reachable, or startable on demand")
        #expect(check == DoctorCheckResult(label: "service reachable, or startable on demand", status: .ok, fix: nil))
        #expect(check?.ok == true)
    }

    @Test func parsesAFailLineWithItsFix() {
        let check = DoctorLineParser.parse("fail  Claude Code MCP server registered  (fix: knock install claude)")
        #expect(check == DoctorCheckResult(label: "Claude Code MCP server registered", status: .fail, fix: "knock install claude"))
        #expect(check?.ok == false)
    }

    @Test func parsesAFailLineWithoutAFixSuffix() {
        let check = DoctorLineParser.parse("fail  claude found")
        #expect(check == DoctorCheckResult(label: "claude found", status: .fail, fix: nil))
    }

    @Test func parsesASkipLineWithItsFix() {
        // KNOCK-20: a runtime that is not found on PATH is skip, not fail.
        let check = DoctorLineParser.parse("skip  codex found  (fix: install Codex)")
        #expect(check == DoctorCheckResult(label: "codex found", status: .skip, fix: "install Codex"))
        #expect(check?.ok == false)
    }

    @Test func ignoresALineThatIsNeitherOkNorFailNorSkip() {
        #expect(DoctorLineParser.parse("") == nil)
        #expect(DoctorLineParser.parse("knock doctor: usage") == nil)
    }

    @Test func ignoresTheLeadingVersionLine() {
        // KNOCK-21: `knock doctor` prints its version first, before any check.
        #expect(DoctorLineParser.parse("knock 0.1.0") == nil)
    }

    @Test func ignoresARegisteredPathWarningLine() {
        // KNOCK-21: a warning does not fail the run and is not a check
        // (KNOCK-20 fold pass 4: the same warning now covers Codex's path too).
        #expect(DoctorLineParser.parse("warn  registered MCP path missing: /stub/knock") == nil)
    }
}

/// Scripts `knock` subcommand output by exact argument list, and records
/// every invocation for assertions. An actor (not a plain class) so
/// mutation from `OnboardingModel`'s background `Task`s is race-free under
/// Swift 6 strict concurrency.
actor FakeCommandRunner: OnboardingCommandRunning {
    private(set) var invocations: [[String]] = []
    private var scripts: [[String]: [(lines: [String], code: Int32)]] = [:]

    func script(_ arguments: [String], lines: [String] = [], code: Int32 = 0) {
        scripts[arguments, default: []].append((lines, code))
    }

    func run(_ arguments: [String], onLine: @escaping @MainActor (String) -> Void) async -> Int32 {
        invocations.append(arguments)
        guard let queue = scripts[arguments], !queue.isEmpty else { return 0 }
        let scripted = queue[0]
        if queue.count > 1 {
            scripts[arguments] = Array(queue.dropFirst())
        }
        for line in scripted.lines {
            await onLine(line)
        }
        return scripted.code
    }
}

private enum OnboardingTestError: Error {
    case timedOut
}

@MainActor
struct OnboardingModelTests {
    private func waitUntil(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        if try await !pollUntil(timeout, condition) { throw OnboardingTestError.timedOut }
    }

    private func makeModel(runner: FakeCommandRunner, fakes: OnboardingFakes = OnboardingFakes()) -> OnboardingModel {
        makeOnboardingModel(runner: runner, fakes: fakes)
    }

    private func rows(_ model: OnboardingModel) -> [OnboardingModel.RuntimeRow]? {
        guard case .loaded(let rows) = model.connectPhase else { return nil }
        return rows
    }

    // MARK: - O1 Connect (unchanged behaviour from KNOCK-20/HAIL-24)

    @Test func startProbesDoctorOnlyAndSkipsInstallWhenAlreadyConnected() async throws {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: [
            "ok    service reachable, or startable on demand",
            "ok    claude found",
            "ok    Claude Code MCP server registered",
            "ok    codex found",
            "ok    Codex MCP server registered",
        ])
        let model = makeModel(runner: runner)

        model.start()
        try await waitUntil { model.connectSucceeded }

        let invocations = await runner.invocations
        #expect(invocations == [["doctor"]])
        guard let rows = rows(model) else {
            Issue.record("expected .loaded")
            return
        }
        #expect(rows.map(\.runtime) == [.claude, .codex])
        #expect(rows.allSatisfy { $0.status == .connected })
        // Step 1's own "reachable once connected" gate, not an automatic
        // advance (contract: "Continue is enabled once at least one
        // runtime is connected" - the tester still clicks it).
        #expect(model.screen == .connect)
    }

    @Test func startShowsNotInstalledForARuntimeMissingFromPathWithNoButton() async throws {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: [
            "ok    service reachable, or startable on demand",
            "ok    claude found",
            "ok    Claude Code MCP server registered",
            "skip  codex found  (fix: install Codex)",
            "skip  Codex MCP server registered  (fix: install Codex first)",
        ])
        let model = makeModel(runner: runner)

        model.start()
        try await waitUntil { model.connectSucceeded }

        guard let rows = rows(model) else {
            Issue.record("expected .loaded")
            return
        }
        #expect(rows.first { $0.runtime == .claude }?.status == .connected)
        #expect(rows.first { $0.runtime == .codex }?.status == .notInstalled)
    }

    @Test func clickingConnectRunsInstallThenDoctorAndCanSucceed() async throws {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: [
            "ok    claude found",
            "fail  Claude Code MCP server registered  (fix: knock install claude)",
        ])
        await runner.script(["doctor"], lines: [
            "ok    claude found",
            "ok    Claude Code MCP server registered",
        ])
        let model = makeModel(runner: runner)

        model.start()
        try await waitUntil {
            rows(model)?.first { $0.runtime == .claude }?.status == .notConnected
        }
        #expect(!model.connectSucceeded)

        model.connect(.claude)
        try await waitUntil { model.connectSucceeded }

        let invocations = await runner.invocations
        #expect(invocations == [["doctor"], ["install", "claude"], ["doctor"]])
    }

    @Test func treatsNoParsedChecksAsFailureRatherThanVacuousSuccess() async throws {
        let runner = FakeCommandRunner()
        let model = makeModel(runner: runner)

        model.start()
        try await waitUntil { rows(model) != nil }

        #expect(!model.connectSucceeded)
        #expect(rows(model)?.allSatisfy { $0.status == .notInstalled } == true)
    }

    // MARK: - Step 1 -> Step 2

    @Test func continueFromConnectDoesNothingUntilARuntimeIsConnected() async throws {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: [
            "fail  Claude Code MCP server registered  (fix: waggle install claude)",
        ])
        let fakes = OnboardingFakes()
        let model = makeModel(runner: runner, fakes: fakes)

        model.start()
        try await waitUntil { rows(model) != nil }

        model.continueFromConnect()
        #expect(model.screen == .connect, "must not advance without a connected runtime")
        #expect(fakes.onboardedCalls == 0)
    }

    @Test func continueFromConnectOpensTheFirstJobAndMarksSetupDone() async throws {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: ["ok    claude found", "ok    Claude Code MCP server registered"])
        let fakes = OnboardingFakes()
        let model = makeModel(runner: runner, fakes: fakes)

        model.start()
        try await waitUntil { model.connectSucceeded }
        model.continueFromConnect()

        #expect(model.screen == .firstJob)
        // From step 2 the person counts as set up: closing the window never brings setup back.
        #expect(fakes.onboardedCalls == 1)
        #expect(model.gettingStarted.isDone(.connect))
        #expect(model.gettingStarted.items.first { $0.line == .connect }?.hint == "Claude Code is connected.")
    }

    @Test func theConnectLineTicksWhenTheDoctorProbeSeesAnAgent() async throws {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: ["ok    codex found", "ok    Codex MCP server registered"])
        let model = makeModel(runner: runner)
        model.start()
        try await waitUntil { model.connectSucceeded }
        #expect(model.gettingStarted.isDone(.connect))
        #expect(model.gettingStarted.state.connectedAgent == "Codex")
    }

    @Test func backFromTheFirstJobReturnsToConnect() async throws {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: ["ok    claude found", "ok    Claude Code MCP server registered"])
        let model = makeModel(runner: runner)
        model.start()
        try await waitUntil { model.connectSucceeded }
        model.continueFromConnect()
        model.backToConnect()
        #expect(model.screen == .connect)
    }

    @Test func theStepModelHasTwoStepsAndTheLabelSaysSo() {
        #expect(OnboardingStep.allCases.count == 2)
        #expect(OnboardingStep.connect.label == "Step 1 of 2")
        #expect(OnboardingStep.firstJob.label == "Step 2 of 2")
        #expect(OnboardingModel.Screen.connect.step == .connect)
        #expect(OnboardingModel.Screen.firstJob.step == .firstJob)
    }

    @Test func showFirstJobPickerOpensStepTwoFromTheList() async throws {
        let model = makeModel(runner: FakeCommandRunner())
        model.showFirstJobPicker()
        #expect(model.screen == .firstJob)
    }

    // MARK: - Reset (the app-menu "Set Up Waggle…" restart)

    @Test func resetReturnsToConnectAndProbesAgain() async throws {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: ["ok    claude found", "ok    Claude Code MCP server registered"])
        let model = makeModel(runner: runner)

        model.start()
        try await waitUntil { model.connectSucceeded }
        model.continueFromConnect()
        #expect(model.screen == .firstJob)

        model.reset()
        #expect(model.screen == .connect)
        // The doctor probe reruns fresh (a second `["doctor"]` invocation).
        let deadline = ContinuousClock.now + .seconds(20)
        var doctorCalls = 0
        while doctorCalls < 2 {
            doctorCalls = (await runner.invocations).filter { $0 == ["doctor"] }.count
            if ContinuousClock.now > deadline { throw OnboardingTestError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - developmentBuildWarning (HAIL-24, unchanged)

    @Test func developmentBuildWarningIsTrueForABuildDirectoryPath() {
        let model = makeOnboardingModel(resolvedKnockBinaryPath: {
            "/Users/x/.fleet/wt/KNOCK-20/apps/macos/.build/Waggle.app/Contents/Resources/knock"
        })
        #expect(model.developmentBuildWarning)
    }

    @Test func developmentBuildWarningIsFalseForThePilotInstallPath() {
        let model = makeOnboardingModel(resolvedKnockBinaryPath: {
            NSHomeDirectory() + "/Applications/Waggle.app/Contents/Resources/knock"
        })
        #expect(!model.developmentBuildWarning)
    }

    @Test func developmentBuildWarningLineOnlyShowsAfterAConnectClickRegistersFromADevPath() async throws {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: ["ok    claude found", "fail  Claude Code MCP server registered  (fix: waggle install claude)"])
        await runner.script(["doctor"], lines: ["ok    claude found", "ok    Claude Code MCP server registered"])
        let model = makeOnboardingModel(runner: runner, resolvedKnockBinaryPath: {
            "/Users/x/.fleet/wt/KNOCK-20/apps/macos/.build/Waggle.app/Contents/Resources/knock"
        })

        model.start()
        try await waitUntil {
            rows(model)?.first { $0.runtime == .claude }?.status == .notConnected
        }
        #expect(model.developmentBuildWarning)
        #expect(!model.didRegisterDevelopmentBuildPath)

        model.connect(.claude)
        try await waitUntil { model.connectSucceeded }
        #expect(model.didRegisterDevelopmentBuildPath)
    }

    // MARK: - Pure helpers

    @Test func extractCaseIdParsesTheTestAskConfirmationLine() {
        let line = "Created test review \"Checkout prototype\" (case c_01J9X4)."
        #expect(OnboardingModel.extractCaseId(line) == "c_01J9X4")
        #expect(OnboardingModel.extractCaseId("no case here") == nil)
    }
}

struct OnboardingStateTests {
    private func withTempHome(_ body: (String) throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.path)
    }

    @Test func isNotOnboardedUntilMarked() {
        withTempHome { home in
            let env = ["KNOCK_HOME": home]
            #expect(!OnboardingState.isOnboarded(environment: env))
            OnboardingState.markOnboarded(environment: env)
            #expect(OnboardingState.isOnboarded(environment: env))
        }
    }

    @Test func forceShowOverridesAnAlreadyOnboardedHome() {
        withTempHome { home in
            let env = ["KNOCK_HOME": home]
            OnboardingState.markOnboarded(environment: env)
            #expect(!OnboardingState.shouldShowAtLaunch(environment: env))

            var forced = env
            forced["KNOCK_SHOW_ONBOARDING"] = "1"
            #expect(OnboardingState.shouldShowAtLaunch(environment: forced))
        }
    }

    @Test func showsAtLaunchForAFreshHome() {
        withTempHome { home in
            #expect(OnboardingState.shouldShowAtLaunch(environment: ["KNOCK_HOME": home]))
        }
    }
}

// KNOCK-17 fold pass 2: macOS 15+ auto-presents `Window` scenes at launch, so
// the onboarding window closes itself in `.onAppear` unless the gate meant to
// show it (fresh install, or KNOCK_SHOW_ONBOARDING=1).
struct OnboardingLaunchPolicyTests {
    private func withTempHome(_ body: (String) throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.path)
    }

    @Test func closesWhenAlreadyOnboarded() {
        withTempHome { home in
            let env = ["KNOCK_HOME": home]
            OnboardingState.markOnboarded(environment: env)
            #expect(OnboardingLaunchPolicy.shouldCloseWhenShownAtLaunch(explicitlyRequested: false, environment: env))
        }
    }

    @Test func staysOpenWhenForcedEvenIfOnboarded() {
        withTempHome { home in
            var env = ["KNOCK_HOME": home]
            OnboardingState.markOnboarded(environment: env)
            env["KNOCK_SHOW_ONBOARDING"] = "1"
            #expect(!OnboardingLaunchPolicy.shouldCloseWhenShownAtLaunch(explicitlyRequested: false, environment: env))
        }
    }

    /// 29 Sep: "Set Up Waggle is not launching the setup" - the window
    /// closed itself on appear for an onboarded user, menu or not.
    @Test func staysOpenWhenOpenedFromSetUpKnockEvenIfOnboarded() {
        withTempHome { home in
            let env = ["KNOCK_HOME": home]
            OnboardingState.markOnboarded(environment: env)
            #expect(!OnboardingLaunchPolicy.shouldCloseWhenShownAtLaunch(explicitlyRequested: true, environment: env))
        }
    }

    @Test func staysOpenForAFreshInstall() {
        withTempHome { home in
            #expect(!OnboardingLaunchPolicy.shouldCloseWhenShownAtLaunch(explicitlyRequested: false, environment: ["KNOCK_HOME": home]))
        }
    }

    /// HAIL-92: first run opens setup, Done writes the marker, and the next
    /// launch (a Sparkle relaunch) must never show it unasked.
    @Test func afterDoneTheNextLaunchNeverShowsIt() {
        withTempHome { home in
            let env = ["KNOCK_HOME": home]
            #expect(OnboardingState.shouldShowAtLaunch(environment: env))
            OnboardingState.markOnboarded(environment: env)
            #expect(!OnboardingState.shouldShowAtLaunch(environment: env))
            #expect(OnboardingLaunchPolicy.shouldCloseWhenShownAtLaunch(explicitlyRequested: false, environment: env))
        }
    }

    /// WAG-348: one explicit open must not keep every later automatic
    /// presentation on screen.
    @Test func explicitOpenIsOneShot() {
        withTempHome { home in
            let env = ["KNOCK_HOME": home]
            OnboardingState.markOnboarded(environment: env)
            var open = OnboardingExplicitOpen()
            open.request()
            let first = open.consume()
            #expect(!OnboardingLaunchPolicy.shouldCloseWhenShownAtLaunch(explicitlyRequested: first, environment: env))
            // Same window re-evaluated (updateNSView): still held open.
            let again = open.consume()
            #expect(again)
            open.windowDidClose()
            // A later automatic presentation closes.
            let later = open.consume()
            #expect(OnboardingLaunchPolicy.shouldCloseWhenShownAtLaunch(explicitlyRequested: later, environment: env))
        }
    }

    @Test func requestBeforeCloseDoesNotSurviveTheClose() {
        var open = OnboardingExplicitOpen()
        open.request()
        open.windowDidClose()
        let held = open.consume()
        #expect(!held)
    }

    @Test func forcedEnvStillShowsAfterOneShotIsSpent() {
        withTempHome { home in
            var env = ["KNOCK_HOME": home]
            OnboardingState.markOnboarded(environment: env)
            env["KNOCK_SHOW_ONBOARDING"] = "1"
            var open = OnboardingExplicitOpen()
            let held = open.consume()
            #expect(!OnboardingLaunchPolicy.shouldCloseWhenShownAtLaunch(explicitlyRequested: held, environment: env))
        }
    }
}
