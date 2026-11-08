import Foundation

/// The PATH an app launched from Finder or `open` actually gets: launchd's
/// minimal default, which has none of the directories a tester's login shell
/// adds via `.zprofile`/`.zshrc` (`~/.local/bin`, `~/.claude/local`,
/// `/opt/homebrew/bin`, `/usr/local/bin` — wherever `claude` or `knock`
/// itself landed). Querying the login shell once, with a short fallback
/// list appended, fixes both `KnockBinaryLocator`'s own PATH search and the
/// `claude` lookup `knock doctor`/`knock install claude` do inside the child
/// `knock` process (Amendments).
struct LoginShellPathResolution {
    let path: String
    /// `false` when the login shell could not be asked (missing, errored, or
    /// timed out) and `path` is only `environment["PATH"]` plus the fallback
    /// directories. Callers use this to avoid asserting "not installed" from
    /// a check that could not really run (see `ProcessCommandRunner`).
    let shellSucceeded: Bool
}

enum LoginShellPath {
    static let fallbackDirectories: [String] = [
        "\(NSHomeDirectory())/.local/bin",
        "\(NSHomeDirectory())/.claude/local",
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]

    /// HAIL-218: nvm adds its bin folder in `.zshrc`, which a login shell that is not
    /// interactive never reads. So the probe asks an interactive login shell (`-lic`) and
    /// brackets the PATH with markers, to skip any text the rc files print. The nvm folders
    /// are also added by hand, newest first, in case the shell probe fails or times out.
    static let pathMarker = "__WAGGLE_PATH__"

    static func nvmDirectories(home: String = NSHomeDirectory()) -> [String] {
        let root = "\(home)/.nvm/versions/node"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(root)/\($0)/bin" }
    }

    static func extractMarkedPath(_ output: String) -> String? {
        let parts = output.components(separatedBy: pathMarker)
        guard parts.count >= 3 else { return nil }
        let path = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runner: LoginShellPathRunning = ProcessLoginShellPathRunner(),
        extraDirectories: [String] = nvmDirectories()
    ) async -> LoginShellPathResolution {
        let shell = environment["SHELL"] ?? "/bin/zsh"
        let command = "printf '%s%s%s' '\(pathMarker)' \"$PATH\" '\(pathMarker)'"
        let output = await runner.run(shell: shell, command: command, timeoutSeconds: 3)
        // A runner may return the bare PATH (no markers): accept it as it is.
        let shellPath = output.flatMap { extractMarkedPath($0) ?? ($0.contains(pathMarker) ? nil : $0) }
        let basePath = shellPath ?? environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"

        var directories = basePath.split(separator: ":").map(String.init)
        let existing = Set(directories)
        for fallback in fallbackDirectories + extraDirectories where !existing.contains(fallback) {
            directories.append(fallback)
        }
        return LoginShellPathResolution(path: directories.joined(separator: ":"), shellSucceeded: shellPath != nil)
    }
}

/// Runs one login-shell command and returns its trimmed stdout, or `nil` on
/// failure or timeout. Injectable so tests never launch a real shell.
protocol LoginShellPathRunning: Sendable {
    func run(shell: String, command: String, timeoutSeconds: TimeInterval) async -> String?
}

/// Runs `<shell> -lic <command>` (`-l` so the shell reads the same login
/// profile a Terminal window would, `-i` so it reads `.zshrc` too: both extend `PATH`).
struct ProcessLoginShellPathRunner: LoginShellPathRunning {
    func run(shell: String, command: String, timeoutSeconds: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-lic", command]

            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()

            let gate = ResumeOnceGate(continuation: continuation)

            process.terminationHandler = { finished in
                guard finished.terminationStatus == 0 else {
                    Task { await gate.resume(nil) }
                    return
                }
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let trimmed = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await gate.resume(trimmed?.isEmpty == false ? trimmed : nil) }
            }

            do {
                try process.run()
            } catch {
                Task { await gate.resume(nil) }
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                if process.isRunning {
                    process.terminate()
                }
                Task { await gate.resume(nil) }
            }
        }
    }
}

/// Resumes a continuation exactly once even when both the termination
/// handler and the timeout watchdog fire (an actor, not a lock, so this is
/// safe under Swift 6 strict concurrency).
private actor ResumeOnceGate {
    private var resumed = false
    private let continuation: CheckedContinuation<String?, Never>

    init(continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: String?) {
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }
}
