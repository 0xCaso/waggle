import Foundation
import Testing

@testable import Knock

/// HAIL-239: the Design helpers card model. A fake runner stands in for `waggle`: no claude CLI runs.
@MainActor
struct DesignHelpersTests {
    @Test func notInstalledWhenStatusSaysSo() async {
        let runner = FakeCommandRunner()
        await runner.script(DesignHelpersCommand.status, lines: ["not installed"])
        let model = DesignHelpersModel(runner: runner)
        await model.refresh()
        #expect(model.isAvailable)
        #expect(!model.isInstalled)
        #expect(model.phase == .idle)
        #expect(await runner.invocations == [DesignHelpersCommand.status])
    }

    @Test func installedWhenStatusSaysSo() async {
        let runner = FakeCommandRunner()
        await runner.script(DesignHelpersCommand.status, lines: ["installed"])
        let model = DesignHelpersModel(runner: runner)
        await model.refresh()
        #expect(model.isInstalled)
    }

    @Test func cardStaysHiddenWhenTheStatusProbeFails() async {
        let runner = FakeCommandRunner()
        await runner.script(DesignHelpersCommand.status, code: 1)
        let model = DesignHelpersModel(runner: runner)
        await model.refresh()
        #expect(!model.isAvailable)
    }

    @Test func nothingRunsUntilTheClick() async {
        let runner = FakeCommandRunner()
        let model = DesignHelpersModel(runner: runner)
        await model.refresh()
        let ran = await runner.invocations
        #expect(!ran.contains(DesignHelpersCommand.add))
        #expect(!ran.contains(DesignHelpersCommand.remove))
    }

    @Test func addRunsTheCommandAndEndsInstalled() async {
        let runner = FakeCommandRunner()
        await runner.script(DesignHelpersCommand.status, lines: ["not installed"])
        await runner.script(DesignHelpersCommand.status, lines: ["installed"])
        let model = DesignHelpersModel(runner: runner)
        await model.refresh()
        await model.set(installed: true)
        #expect(model.isInstalled)
        #expect(model.phase == .idle)
        #expect(await runner.invocations.contains(DesignHelpersCommand.add))
    }

    @Test func isInstallingWhileTheCommandRuns() async throws {
        let runner = GateRunner()
        let model = DesignHelpersModel(runner: runner)
        let task = Task { await model.set(installed: true) }
        _ = try await pollUntil(.seconds(20)) { model.phase == .installing }
        #expect(model.phase == .installing)
        #expect(model.isWorking)
        await runner.open()
        await task.value
    }

    @Test func aFailedAddShowsTheMessageAndKeepsTheAddButton() async {
        let runner = FakeCommandRunner()
        await runner.script(DesignHelpersCommand.add, code: 1)
        await runner.script(DesignHelpersCommand.status, lines: ["not installed"])
        let model = DesignHelpersModel(runner: runner)
        await model.set(installed: true)
        #expect(model.phase == .failed(DesignHelpersCopy.addFailed))
        #expect(!model.isInstalled)
    }

    @Test func removeRunsTheCommandAndEndsNotInstalled() async {
        let runner = FakeCommandRunner()
        await runner.script(DesignHelpersCommand.status, lines: ["installed"])
        await runner.script(DesignHelpersCommand.status, lines: ["not installed"])
        let model = DesignHelpersModel(runner: runner)
        await model.refresh()
        await model.set(installed: false)
        #expect(!model.isInstalled)
        #expect(model.phase == .idle)
        #expect(await runner.invocations.contains(DesignHelpersCommand.remove))
    }

    @Test func aFailedRemoveShowsTheMessage() async {
        let runner = FakeCommandRunner()
        await runner.script(DesignHelpersCommand.status, lines: ["installed"])
        await runner.script(DesignHelpersCommand.remove, code: 1)
        let model = DesignHelpersModel(runner: runner)
        await model.refresh()
        await model.set(installed: false)
        #expect(model.isInstalled)
        #expect(model.phase == .failed(DesignHelpersCopy.removeFailed))
    }

    @Test func copyHasNoEmDash() {
        for text in [DesignHelpersCopy.title, DesignHelpersCopy.body, DesignHelpersCopy.add, DesignHelpersCopy.addFailed, DesignHelpersCopy.removeFailed] {
            #expect(!text.contains("\u{2014}"))
        }
        #expect(DesignHelpersCopy.body == "Impeccable helps your agents shape, critique and polish prototypes. Free, open source (Apache 2.0).")
    }

    /// Holds `add` until `open()`, so a test can look at the in-between state.
    private actor GateRunner: OnboardingCommandRunning {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false

        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }

        func run(_ arguments: [String], onLine: @escaping @MainActor (String) -> Void) async -> Int32 {
            if arguments == DesignHelpersCommand.add, !opened {
                await withCheckedContinuation { continuation = $0 }
            }
            if arguments == DesignHelpersCommand.status { await onLine("installed") }
            return 0
        }
    }
}
