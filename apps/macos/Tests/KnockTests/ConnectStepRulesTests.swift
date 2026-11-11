import Foundation
import Testing
@testable import Knock

/// Setup step 1: each row has one action, "Check again" searches again, "Skip for now" always leaves.
@MainActor
struct ConnectStepRulesTests {
    private typealias Status = OnboardingModel.RuntimeRow.Status

    @Test func aFoundAgentOffersConnect() {
        #expect(ConnectStepRules.action(for: .claude, status: .notConnected) == .connect)
        #expect(ConnectStepRules.action(for: .codex, status: .notConnected) == .connect)
    }

    @Test func aMissingAgentOffersGetWithItsInstallPage() {
        #expect(ConnectStepRules.action(for: .claude, status: .notInstalled) == .get(ConnectStepRules.installURL(for: .claude)))
        #expect(ConnectStepRules.action(for: .codex, status: .notInstalled) == .get(ConnectStepRules.installURL(for: .codex)))
        #expect(ConnectStepRules.installURL(for: .claude) != ConnectStepRules.installURL(for: .codex))
        #expect(ConnectStepRules.installURL(for: .codex).scheme == "https")
    }

    @Test func aConnectedAgentShowsAStateNotAControl() {
        #expect(ConnectStepRules.action(for: .claude, status: .connected) == .connected)
        #expect(ConnectStepRules.claudeAppAction(isConnected: true) == .connected)
        #expect(ConnectStepRules.claudeAppAction(isConnected: false) == .connect)
    }

    @Test func aRunningCheckOrConnectHasNoButtonAndAnUncheckableRowLeavesItToCheckAgain() {
        #expect(ConnectStepRules.action(for: .codex, status: .probing) == .working)
        #expect(ConnectStepRules.action(for: .codex, status: .connecting) == .working)
        #expect(ConnectStepRules.action(for: .codex, status: .couldNotCheck) == .none)
    }

    @Test func skipIsAvailableOnStepOneAndNotOnStepTwo() {
        #expect(ConnectStepRules.skipIsAvailable(on: .connect))
        #expect(!ConnectStepRules.skipIsAvailable(on: .firstJob))
    }

    @Test func checkAgainWaitsForTheSearchAndTheConnectToEnd() {
        let rows = [OnboardingModel.RuntimeRow(runtime: .claude, status: .notInstalled)]
        #expect(ConnectStepRules.checkAgainIsAvailable(phase: .loaded(rows: rows)))
        #expect(!ConnectStepRules.checkAgainIsAvailable(phase: .checking))
        #expect(!ConnectStepRules.checkAgainIsAvailable(phase: .idle))
        let connecting = [OnboardingModel.RuntimeRow(runtime: .claude, status: .connecting)]
        #expect(!ConnectStepRules.checkAgainIsAvailable(phase: .loaded(rows: connecting)))
    }

    @Test func skipLeavesSetupWithNoAgentFound() async throws {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: ["skip  claude found  (fix: install Claude Code)", "skip  codex found  (fix: install Codex)"])
        let fakes = OnboardingFakes()
        let model = makeOnboardingModel(runner: runner, fakes: fakes)
        model.start()
        let loaded = try await pollUntil(.seconds(10)) { if case .loaded = model.connectPhase { return true } else { return false } }
        #expect(loaded)
        #expect(!model.connectSucceeded)
        model.skipSetup()
        #expect(fakes.skipCalls == 1)
        #expect(fakes.onboardedCalls == 1)
    }

    @Test func skipLeavesSetupBeforeTheSearchEnds() {
        let fakes = OnboardingFakes()
        let model = makeOnboardingModel(fakes: fakes)
        model.skipSetup()
        #expect(fakes.skipCalls == 1)
    }

    @Test func checkAgainRunsTheSearchAgain() async throws {
        let runner = FakeCommandRunner()
        let model = makeOnboardingModel(runner: runner)
        model.start()
        _ = try await pollUntil(.seconds(10)) { if case .loaded = model.connectPhase { return true } else { return false } }
        model.recheck()
        var count = 0
        for _ in 0..<500 {
            count = await runner.invocations.filter { $0 == ["doctor"] }.count
            if count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(count == 2)
    }
}
