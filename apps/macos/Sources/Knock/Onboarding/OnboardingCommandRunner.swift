import Foundation

/// Runs one `knock` subcommand and streams its stdout, one call per line.
/// Injectable so tests can assert exactly which subcommand ran without
/// shelling out to a real `knock` binary (mirrors `ServiceControl`'s
/// injectable `launch` closure).
protocol OnboardingCommandRunning: Sendable {
    /// `onLine` is always called on the main actor, once per stdout line
    /// (newline stripped, blank lines skipped). Returns the process exit
    /// code, or a negative value when the process could not be started.
    func run(_ arguments: [String], onLine: @escaping @MainActor (String) -> Void) async -> Int32
}

/// Runs `knock <arguments>` by resolving the binary through
/// `KnockBinaryLocator` first (see that type's doc comment for why a plain
/// `/usr/bin/env waggle` is not enough for an app launched from Finder), and
/// passes the child process a PATH extended through the user's login shell
/// (`LoginShellPath`) for the same reason — `waggle doctor`/`waggle install
/// claude` shell out to `claude` themselves, and need to find it too.
struct ProcessCommandRunner: OnboardingCommandRunning {
    private let environment: [String: String]
    private let bundledBinaryURL: URL?
    private let loginShellPathRunner: LoginShellPathRunning
    /// Longest a child may run. After it, `run` returns what was read so far
    /// and `-2`, so a stuck child never leaves a caller waiting (HAIL-126).
    private let timeoutSeconds: Double

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledBinaryURL: URL? = KnockBinaryLocator.bundledBinary(),
        loginShellPathRunner: LoginShellPathRunning = ProcessLoginShellPathRunner(),
        timeoutSeconds: Double = 20
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.environment = environment
        self.bundledBinaryURL = bundledBinaryURL
        self.loginShellPathRunner = loginShellPathRunner
    }

    func run(_ arguments: [String], onLine: @escaping @MainActor (String) -> Void) async -> Int32 {
        let pathResolution = await LoginShellPath.resolve(environment: environment, runner: loginShellPathRunner)
        var childEnvironment = environment
        childEnvironment["PATH"] = pathResolution.path

        guard let binaryURL = KnockBinaryLocator.resolve(environment: childEnvironment, bundledBinaryURL: bundledBinaryURL) else {
            await onLine("fail  waggle found  (fix: reinstall Waggle, or set KNOCK_BIN to its path)")
            return -1
        }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = binaryURL
            process.arguments = arguments
            process.environment = childEnvironment

            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()

            let accumulator = LineAccumulator(onLine: { line in
                onLine(Self.rewriteFixTextIfPathResolutionFailed(line, shellSucceeded: pathResolution.shellSucceeded))
            })
            let gate = ProcessCompletionGate(continuation: continuation)
            // After a timeout, a doctor run gets one "could not check" line per
            // runtime, so Agents shows "Couldn't check" and Retry (HAIL-126).
            let timeoutLines = arguments.first == "doctor"
                ? Runtime.allCases.map { "skip  \($0.rawValue) found  (fix: Could not check)" }
                : []

            // One AsyncStream keeps chunk order (HAIL-115): a single consumer
            // appends every chunk, then flushes, then notes EOF.
            let (chunks, chunkSink) = AsyncStream.makeStream(of: Data.self)
            Task {
                await accumulator.consume(chunks)
                if await gate.timedOutBeforeEOF {
                    for line in timeoutLines { await onLine(line) }
                }
                await gate.noteEOF()
            }

            process.terminationHandler = { finished in
                Task { await gate.noteExit(finished.terminationStatus) }
            }

            do {
                try process.run()
            } catch {
                chunkSink.finish()
                continuation.resume(returning: -1)
                return
            }

            // The parent must close its copy of the write end, or the read
            // below never sees EOF. Foundation's readabilityHandler (used
            // before HAIL-126) depended on a dispatch source that is dropped
            // when nothing holds the Pipe, and could miss the last empty read
            // under load, so `run` never returned. A plain blocking read on
            // its own thread, holding the pipe, always sees EOF.
            try? stdout.fileHandleForWriting.close()
            let reader = stdout.fileHandleForReading
            let descriptor = reader.fileDescriptor
            Thread.detachNewThread {
                // Hold the pipe so its descriptor stays open. POSIX `read`
                // returns what is there; `FileHandle.read(upToCount:)` would
                // wait to fill the whole buffer.
                withExtendedLifetime(reader) {
                    var buffer = [UInt8](repeating: 0, count: 65536)
                    while true {
                        let count = read(descriptor, &buffer, buffer.count)
                        if count > 0 {
                            chunkSink.yield(Data(buffer[0..<count]))
                        } else if count < 0, errno == EINTR {
                            continue
                        } else {
                            break
                        }
                    }
                    chunkSink.finish()
                }
            }

            let seconds = timeoutSeconds
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                switch await gate.beginTimeout() {
                case .ignore:
                    return
                case .consumerReports:
                    if process.isRunning { process.terminate() }
                    chunkSink.finish()
                case .reportNow:
                    if process.isRunning { process.terminate() }
                    for line in timeoutLines { await onLine(line) }
                    await gate.finishTimeout()
                }
            }
        }
    }

    /// The login-shell PATH probe failing does not mean Claude Code (or,
    /// KNOCK-20, Codex) is missing — it means the check could not run with a
    /// trustworthy PATH (Amendments: "Never show 'Fix: install Claude Code'
    /// when the check could not run; say 'Could not check' instead").
    /// Rewrites only a "found" check's own fix text (a "skip" line since
    /// KNOCK-20 — a missing runtime is not a failure), leaving every other
    /// line (including a genuine "claude/codex found" skip when the shell
    /// probe succeeded) untouched.
    static func rewriteFixTextIfPathResolutionFailed(_ line: String, shellSucceeded: Bool) -> String {
        guard !shellSucceeded, line.hasPrefix("skip"), line.contains(" found"),
              let fixRange = line.range(of: "(fix:")
        else { return line }
        return String(line[line.startIndex..<fixRange.lowerBound]) + "(fix: Could not check)"
    }
}

/// Buffers raw stdout bytes into lines off the main actor (the readability
/// handler fires on an arbitrary queue), then delivers each line to `onLine`
/// on the main actor. An actor, not a plain class, so `buffer` mutation is
/// safe under Swift 6 strict concurrency without a manual lock.
actor LineAccumulator {
    private var buffer = Data()
    private let onLine: @MainActor (String) -> Void

    init(onLine: @escaping @MainActor (String) -> Void) {
        self.onLine = onLine
    }

    /// Reads `chunks` in order until it ends, then delivers the unfinished
    /// last line. The one consumer for a child's stdout.
    func consume(_ chunks: AsyncStream<Data>) async {
        for await data in chunks { await append(data) }
        await flush()
    }

    func append(_ data: Data) async {
        buffer.append(data)
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newlineIndex]
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
            await onLine(line)
        }
    }

    /// Delivers a final line left in `buffer` with no trailing newline (a
    /// child that writes its last line without `\n` before exiting). Called
    /// once, at EOF.
    func flush() async {
        defer { buffer.removeAll() }
        guard let line = String(data: buffer, encoding: .utf8), !line.isEmpty else { return }
        await onLine(line)
    }
}

/// Resumes `run`'s continuation once the child's stdout has hit EOF (every
/// line reached `LineAccumulator`) and the process has exited, whichever
/// comes first, waiting for the other. A timeout resumes it without the exit,
/// with code -2, after the "could not check" lines are delivered. An actor, not
/// a lock, so this is safe under Swift 6 strict concurrency.
private actor ProcessCompletionGate {
    enum TimeoutAction {
        /// The run already ended.
        case ignore
        /// EOF is still pending: the consumer delivers the lines, then notes EOF.
        case consumerReports
        /// EOF already came but the child never exited: the timer delivers the lines.
        case reportNow
    }

    private var reachedEOF = false
    private var exitCode: Int32?
    private var timedOut = false
    private var reportPending = false
    private var resumed = false
    private let continuation: CheckedContinuation<Int32, Never>

    init(continuation: CheckedContinuation<Int32, Never>) {
        self.continuation = continuation
    }

    var timedOutBeforeEOF: Bool { timedOut && !reportPending }

    func noteEOF() {
        reachedEOF = true
        resumeIfReady()
    }

    func noteExit(_ code: Int32) {
        exitCode = code
        resumeIfReady()
    }

    func beginTimeout() -> TimeoutAction {
        guard !resumed else { return .ignore }
        timedOut = true
        if reachedEOF {
            reportPending = true
            return .reportNow
        }
        return .consumerReports
    }

    func finishTimeout() {
        reportPending = false
        resumeIfReady()
    }

    private func resumeIfReady() {
        guard !resumed, !reportPending, reachedEOF, exitCode != nil || timedOut else { return }
        resumed = true
        continuation.resume(returning: timedOut ? -2 : (exitCode ?? -2))
    }
}

/// One parsed line of `knock doctor` output (docs/protocol-mvp.md "One
/// binary"; format fixed by `daemon/src/cli/doctor.ts`: `ok    <label>`,
/// `fail  <label>  (fix: <fix>)` or `skip  <label>  (fix: <fix>)`. KNOCK-20
/// added `skip` for a runtime that is not found on PATH — neither Claude
/// Code nor Codex is required, so a missing one is not a failure.
enum DoctorCheckStatus: Equatable {
    case ok
    case fail
    case skip
}

struct DoctorCheckResult: Equatable, Identifiable {
    var id: String { label }
    let label: String
    let status: DoctorCheckStatus
    let fix: String?

    var ok: Bool { status == .ok }
}

enum DoctorLineParser {
    private static let prefixes: [(String, DoctorCheckStatus)] = [
        ("ok", .ok),
        ("fail", .fail),
        ("skip", .skip),
    ]

    /// Parses one `knock doctor` stdout line. Returns `nil` for a line that
    /// is not a check (there are none today, but a future `knock doctor`
    /// build note or blank separator should not crash the parser).
    static func parse(_ line: String) -> DoctorCheckResult? {
        for (prefix, status) in prefixes where line.hasPrefix(prefix) {
            let rest = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            guard let fixRange = rest.range(of: "(fix:"), rest.hasSuffix(")") else {
                return rest.isEmpty ? nil : DoctorCheckResult(label: String(rest), status: status, fix: nil)
            }
            let label = rest[rest.startIndex..<fixRange.lowerBound].trimmingCharacters(in: .whitespaces)
            let fixStart = rest.index(fixRange.lowerBound, offsetBy: 5)
            let fixEnd = rest.index(before: rest.endIndex)
            let fix = String(rest[fixStart..<fixEnd]).trimmingCharacters(in: .whitespaces)
            return DoctorCheckResult(label: label, status: status, fix: fix.isEmpty ? nil : fix)
        }
        return nil
    }
}
