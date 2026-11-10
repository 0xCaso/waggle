import Testing
import Foundation
@testable import Knock

/// HAIL-115: Settings > Agents said "Not installed" while sessions were live,
/// because the last doctor lines (after one line per session) were lost: the
/// runner handled each stdout chunk and the EOF in separate unordered tasks.
@MainActor
struct CommandRunnerOrderingTests {
    private final class Lines: @unchecked Sendable {
        var all: [String] = []
    }

    @Test func accumulatorDeliversEveryLineInOrderWhenChunksSplitMidLine() async {
        let lines = (0..<300).map { "ok    session \($0) live" } + ["ok    claude found", "ok    Claude Code MCP server registered"]
        let bytes = Data((lines.joined(separator: "\n") + "\n").utf8)
        let (chunks, sink) = AsyncStream.makeStream(of: Data.self)
        let seen = Lines()
        let accumulator = LineAccumulator(onLine: { seen.all.append($0) })

        let consumer = Task { await accumulator.consume(chunks) }
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 37, bytes.count)
            sink.yield(bytes[offset..<end])
            offset = end
        }
        sink.finish()
        await consumer.value

        #expect(seen.all == lines)
    }

    @Test func accumulatorFlushesALastLineWithoutNewline() async {
        let (chunks, sink) = AsyncStream.makeStream(of: Data.self)
        let seen = Lines()
        let accumulator = LineAccumulator(onLine: { seen.all.append($0) })
        sink.yield(Data("ok    a\nok    claude found".utf8))
        sink.finish()
        await accumulator.consume(chunks)
        #expect(seen.all == ["ok    a", "ok    claude found"])
    }

    private static func makeScript(_ body: String) throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("knock-runner-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("knock")
        try ("#!/bin/sh\n" + body).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (dir, script)
    }

    private static let manyLinesBody = """
        i=0
        while [ $i -lt 200 ]; do echo "ok    session $i live"; i=$((i+1)); done
        echo "ok    claude found"
        echo "ok    Claude Code MCP server registered"
        echo "ok    codex found"
        echo "ok    Codex MCP server registered"
        """

    private static func runner(_ script: URL, timeoutSeconds: Double = 20) -> ProcessCommandRunner {
        ProcessCommandRunner(
            environment: ["PATH": "/usr/bin:/bin"], bundledBinaryURL: script,
            loginShellPathRunner: FakeLoginShellPathRunner(response: "/usr/bin:/bin"),
            timeoutSeconds: timeoutSeconds)
    }

    /// A real child process that prints many session lines, then the found
    /// lines, then exits at once. Repeated, because the old race was timing.
    @Test func runReturnsTheLastLinesOfAFastChildThatPrintsManyLines() async throws {
        let (dir, script) = try Self.makeScript(Self.manyLinesBody)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = Self.runner(script)

        for _ in 0..<25 {
            var checks: [DoctorCheckResult] = []
            let code = await runner.run(["doctor"], onLine: { line in
                if let check = DoctorLineParser.parse(line) { checks.append(check) }
            })
            #expect(code == 0)
            #expect(checks.count == 204)
            for runtime in Runtime.allCases {
                #expect(OnboardingModel.status(for: runtime, in: checks) == .connected)
            }
        }
    }

    /// HAIL-126: the full suite hung the test above. This runs many children
    /// at once, the load that exposed it, and fails if any run never returns.
    @Test func manyConcurrentRunsAllReturnEveryLine() async throws {
        let (dir, script) = try Self.makeScript(Self.manyLinesBody)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = Self.runner(script)

        let counts = await withTaskGroup(of: (Int32, Int)?.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    let seen = Lines()
                    let result = await Self.withDeadline(seconds: 60) {
                        await runner.run(["doctor"], onLine: { seen.all.append($0) })
                    }
                    return result.map { ($0, seen.all.count) }
                }
            }
            var out: [(Int32, Int)?] = []
            for await item in group { out.append(item) }
            return out
        }
        #expect(counts.count == 50)
        for item in counts {
            #expect(item?.0 == 0)
            #expect(item?.1 == 204)
        }
    }

    /// A child that never exits must not leave Agents on "Checking...".
    @Test func aChildThatNeverExitsEndsWithATimeoutAndCouldNotCheckLines() async throws {
        let (dir, script) = try Self.makeScript("echo \"ok    session 1 live\"\nexec sleep 30")
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = Self.runner(script, timeoutSeconds: 0.5)

        var checks: [DoctorCheckResult] = []
        let started = ContinuousClock.now
        let code = await runner.run(["doctor"], onLine: { line in
            if let check = DoctorLineParser.parse(line) { checks.append(check) }
        })
        #expect(code == -2)
        #expect(ContinuousClock.now - started < .seconds(20))
        #expect(checks.first?.label == "session 1 live")
        for runtime in Runtime.allCases {
            #expect(OnboardingModel.status(for: runtime, in: checks) == .couldNotCheck)
        }
    }

    /// A background grandchild keeps the pipe open after the child exits, so
    /// EOF never comes. The timeout still ends the run.
    @Test func aGrandchildHoldingThePipeOpenEndsWithATimeout() async throws {
        let (dir, script) = try Self.makeScript("echo \"ok    claude found\"\nsleep 30 &\nexit 0")
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = Self.runner(script, timeoutSeconds: 0.5)

        var checks: [DoctorCheckResult] = []
        let code = await runner.run(["doctor"], onLine: { line in
            if let check = DoctorLineParser.parse(line) { checks.append(check) }
        })
        #expect(code == -2)
        #expect(checks.first?.label == "claude found")
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    /// Returns nil when `work` has not finished after `seconds`. Unstructured
    /// tasks, because a task group would wait for a hung `work` forever.
    private static func withDeadline<T: Sendable>(
        seconds: Double, _ work: @escaping @Sendable () async -> T
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = Once()
            Task {
                let value = await work()
                if once.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    @Test func aLiveSessionMakesTheRuntimeConnectedWhateverTheProbeSaid() {
        let none: [DoctorCheckResult] = []
        #expect(OnboardingModel.status(for: .claude, in: none) == .notInstalled)
        #expect(OnboardingModel.status(for: .claude, in: none, liveRuntimes: [.claude]) == .connected)
        #expect(OnboardingModel.status(for: .codex, in: none, liveRuntimes: [.claude]) == .notInstalled)
    }

    @Test func agentsPageShowsLiveRuntimeAsConnectedEvenWhenDoctorOutputIsEmpty() async {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: ["ok    session 1 live"])
        let model = AgentsSettingsModel(runner: runner, liveRuntimes: { [.claude] })
        await model.start()
        #expect(model.rows.first { $0.runtime == .claude }?.status == .connected)
        #expect(model.rows.first { $0.runtime == .codex }?.status == .notInstalled)
    }

    @Test func couldNotCheckIsItsOwnStatusAndRetryProbesAgain() async throws {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: ["skip  claude found  (fix: Could not check)"])
        await runner.script(["doctor"], lines: ["ok    claude found", "ok    Claude Code MCP server registered"])
        let model = AgentsSettingsModel(runner: runner)
        await model.start()
        #expect(model.rows.first { $0.runtime == .claude }?.status == .couldNotCheck)

        model.retry()
        let deadline = ContinuousClock.now + .seconds(20)
        while model.rows.first(where: { $0.runtime == .claude })?.status != .connected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.rows.first { $0.runtime == .claude }?.status == .connected)
    }

}
