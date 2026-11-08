import Foundation

// WAG-263: Superset and Conductor as launch targets for "Start a new session".

/// What one run of a command line tool gave back.
struct CLIResult: Equatable, Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var timedOut = false

    var succeeded: Bool { exitCode == 0 && !timedOut }
}

/// Runs one command line tool with an argument list (never a shell string). A fake stands in for
/// it in every test: no test runs the real `superset`.
protocol CLIRunning: Sendable {
    func run(executable: String, arguments: [String], searchPath: String, timeout: TimeInterval) async -> CLIResult
}

/// The real runner: `Process` on a background queue, killed after `timeout`, never on the main thread.
struct ProcessCLIRunner: CLIRunning {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    func run(executable: String, arguments: [String], searchPath: String, timeout: TimeInterval) async -> CLIResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = searchPath
                process.environment = environment
                process.standardInput = FileHandle.nullDevice
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: CLIResult(exitCode: -1, stdout: "", stderr: "\(error)"))
                    return
                }
                let timedOut = Flag()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { timedOut.set(); process.terminate() }
                }
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: CLIResult(
                    exitCode: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self),
                    timedOut: timedOut.isSet))
            }
        }
    }
}

/// Where Superset's state is on this Mac. `ready` still needs a project for the folder, which
/// the launch looks up again.
enum SupersetStatus: Equatable, Sendable {
    case ready
    case blocked(LaunchBlock)
}

/// Pure builders and parsers for the Superset CLI. Everything the prompt touches goes in an
/// argument list, so quotes, newlines and `$` need no escaping.
enum SupersetCommand {
    /// Longest wait for a check (about 2 s, WAG-263).
    static let checkTimeout: TimeInterval = 2
    /// Creating a workspace checks out a worktree, so it gets longer.
    static let createTimeout: TimeInterval = 120
    static let openTimeout: TimeInterval = 15

    static let projectsArguments = ["projects", "list", "--local", "--json"]

    /// `superset` on the login-shell PATH, else in `~/.superset/bin` where the app puts its CLI.
    static func findCLI(searchPath: String, homeDirectory: String, fileManager: FileManager = .default) -> String? {
        let extended = searchPath + ":" + homeDirectory + "/.superset/bin"
        return NewSessionCommand.findExecutable(named: "superset", searchPath: extended, fileManager: fileManager)
    }

    static func createArguments(projectID: String, name: String, branch: String, agent: String, prompt: String) -> [String] {
        [
            "ws", "create", "--local", "--project", projectID, "--name", name, "--branch", branch,
            "--agent", agent, "--prompt", prompt, "--quiet",
        ]
    }

    static func openArguments(workspaceID: String) -> [String] {
        ["ws", "open", workspaceID, "--local"]
    }

    static func agentID(for target: LaunchTarget) -> String {
        target == .codexSuperset ? "codex" : "claude"
    }

    /// A short workspace name: the topic on one line, cut at 60 characters, else a plain default.
    static func shortName(topic: String) -> String {
        let line = DocumentPrompt.cleaned(topic)
        if line.isEmpty { return "Waggle session" }
        return String(line.prefix(60)).trimmingCharacters(in: .whitespaces)
    }

    /// A git-safe branch slug: lower case letters, digits and single dashes, then `-<suffix>` so a
    /// second start on the same topic gets its own branch.
    static func branchSlug(topic: String, suffix: String) -> String {
        var slug = ""
        for scalar in topic.lowercased().unicodeScalars {
            let ok = (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
            if ok { slug.unicodeScalars.append(scalar) } else if !slug.hasSuffix("-") { slug.append("-") }
        }
        let trimmed = String(slug.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = trimmed.isEmpty ? "waggle" : trimmed
        return suffix.isEmpty ? base : "\(base)-\(suffix)"
    }

    static func randomSuffix() -> String {
        String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(4))
    }

    /// The same folder written two ways compares equal: `..` removed, no trailing slash, the
    /// `/private` prefix of the three system links dropped, and symlinks resolved. A folder under
    /// Documents, Desktop or Downloads is compared as text only (WAG-319): resolving it would stat
    /// the folder, and macOS asks "Waggle would like to access files in your Documents folder" for
    /// every project folder in the list, again and again.
    static func normalizedPath(
        _ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        if parts.count >= 2, parts[0] == "private", ["var", "tmp", "etc"].contains(parts[1]) { parts.removeFirst() }
        let text = "/" + parts.joined(separator: "/")
        if isPrivacyProtected(text, home: home) { return text }
        return URL(fileURLWithPath: text).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Folders macOS guards with a privacy prompt. Text only, no disk access.
    static func isPrivacyProtected(_ path: String, home: String) -> Bool {
        let root = home.hasSuffix("/") ? String(home.dropLast()) : home
        return ["Documents", "Desktop", "Downloads", "Library/Mobile Documents"].contains { folder in
            let prefix = "\(root)/\(folder)"
            return path == prefix || path.hasPrefix(prefix + "/")
        }
    }

    private static let pathKeys = ["path", "repoPath", "repositoryPath", "localPath", "rootPath", "mainRepoPath", "folder"]

    /// The id of the project whose folder is `folder`, from `projects list --json`. Accepts a bare
    /// array or an object that holds one (`projects`, `data`, `items`, `results`). The field names
    /// are inferred, not verified (see the report).
    static func matchProject(listJSON: String, folder: String) -> String? {
        guard let data = listJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var items: [[String: Any]] = []
        if let array = root as? [[String: Any]] {
            items = array
        } else if let object = root as? [String: Any] {
            for key in ["projects", "data", "items", "results"] {
                if let array = object[key] as? [[String: Any]] { items = array; break }
            }
        }
        let wanted = normalizedPath(folder)
        for item in items {
            guard let id = (item["id"] as? String) ?? (item["projectId"] as? String), !id.isEmpty else { continue }
            for key in pathKeys {
                if let path = item[key] as? String, !path.isEmpty, normalizedPath(path) == wanted { return id }
            }
        }
        return nil
    }

    /// The workspace id from `ws create`: JSON with an `id` (top level or under `workspace`/`data`),
    /// else the last non-empty line of plain output (`--quiet` prints the id).
    static func workspaceID(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) {
            guard let object = root as? [String: Any] else { return nil }
            if let id = object["id"] as? String, !id.isEmpty { return id }
            for key in ["workspace", "data"] {
                if let inner = object[key] as? [String: Any], let id = inner["id"] as? String, !id.isEmpty { return id }
            }
            return nil
        }
        let last = trimmed.components(separatedBy: .newlines).last?.trimmingCharacters(in: .whitespaces) ?? ""
        return last.isEmpty || last.contains(" ") ? nil : last
    }

    /// Looks for the CLI, then runs `projects list` once (about 2 s at most) and turns the answer
    /// into a status. It never signs in, starts the service or adds a project.
    static func check(
        folder: String, searchPath: String, homeDirectory: String, runner: CLIRunning
    ) async -> (status: SupersetStatus, projectID: String?) {
        guard let cli = findCLI(searchPath: searchPath, homeDirectory: homeDirectory) else {
            return (.blocked(.notOnMac), nil)
        }
        let result = await runner.run(executable: cli, arguments: projectsArguments, searchPath: searchPath, timeout: checkTimeout)
        guard result.succeeded else {
            let text = (result.stdout + " " + result.stderr).lowercased()
            let signedOut = !result.timedOut
                && ["not logged in", "auth login", "unauthorized", "not authenticated", "sign in"].contains { text.contains($0) }
            return (.blocked(signedOut ? .signIn : .startService), nil)
        }
        guard let id = matchProject(listJSON: result.stdout, folder: folder) else { return (.blocked(.addFolder), nil) }
        return (.ready, id)
    }
}

/// What a Superset launch ended with.
enum SupersetLaunchResult: Equatable, Sendable {
    case started
    case failed(String)
}

/// Makes the workspace, starts the agent with the prompt, then opens the workspace in the app.
struct SupersetLauncher: Sendable {
    let runner: CLIRunning
    let homeDirectory: String
    var suffix: @Sendable () -> String = { SupersetCommand.randomSuffix() }

    func launch(target: LaunchTarget, folder: String, topic: String, prompt: String, searchPath: String) async -> SupersetLaunchResult {
        let checked = await SupersetCommand.check(
            folder: folder, searchPath: searchPath, homeDirectory: homeDirectory, runner: runner)
        guard case .ready = checked.status, let projectID = checked.projectID,
              let cli = SupersetCommand.findCLI(searchPath: searchPath, homeDirectory: homeDirectory)
        else {
            if case .blocked(let block) = checked.status {
                return .failed(block == .notOnMac
                    ? "Waggle could not find Superset on this Mac. Copy the prompt and paste it where you work."
                    : "\(block.text). Then try again, or copy the prompt instead.")
            }
            return .failed("Waggle could not reach Superset. Copy the prompt instead.")
        }
        let create = await runner.run(
            executable: cli,
            arguments: SupersetCommand.createArguments(
                projectID: projectID, name: SupersetCommand.shortName(topic: topic),
                branch: SupersetCommand.branchSlug(topic: topic, suffix: suffix()),
                agent: SupersetCommand.agentID(for: target), prompt: prompt),
            searchPath: searchPath, timeout: SupersetCommand.createTimeout)
        guard create.succeeded, let workspaceID = SupersetCommand.workspaceID(from: create.stdout) else {
            return .failed("Superset could not make the workspace. Copy the prompt instead.")
        }
        let open = await runner.run(
            executable: cli, arguments: SupersetCommand.openArguments(workspaceID: workspaceID),
            searchPath: searchPath, timeout: SupersetCommand.openTimeout)
        guard open.succeeded else {
            return .failed("Superset made the workspace and started the agent, but could not open it. Look for it in Superset.")
        }
        return .started
    }
}

/// `conductor://prompt=<enc>&path=<enc folder>` (conductor.build/docs/core/deep-links). A flat
/// query straight after `conductor://`, no host and no path, so `URLComponents` cannot build it.
/// Conductor pre-fills the prompt in a new worktree workspace; the person presses Enter.
enum ConductorURL {
    /// Any `conductor://` URL, to ask which app handles the scheme.
    static let schemeProbe = URL(string: "conductor://")!

    private static let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func build(prompt: String, folder: String) -> URL? {
        URL(string: "conductor://prompt=\(encode(prompt))&path=\(encode(folder))")
    }
}
