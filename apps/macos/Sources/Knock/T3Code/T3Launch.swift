import Foundation

// WAG-264: start a thread in T3 Code with the prompt sent.
//
// Facts checked at the tag v0.0.46-nightly.20261005.2667 (the operator's nightly):
// - `apps/server/src/mcp/McpHttpServer.ts`: `/mcp` takes only credentials the server itself hands to
//   the agents it starts (`McpSessionRegistry`). A token from `t3 auth session issue` gets a 401
//   there. So the `t3_thread_launch` tool exists but Waggle cannot reach it. Waggle uses the
//   documented fallback: HTTP `/api/projects` plus the WebSocket call `orchestration.launchThread`.
// - `apps/server/scripts/verify-background-live.ts` runs this same sequence (bearer token, project,
//   `/api/auth/websocket-ticket`, `/ws?orchestrationProtocol=2&wsTicket=`, `launchThread`).

/// Where T3 Code's server runs, and what its server says about it.
enum T3Runtime {
    /// `com.t3tools.t3code`: the stable and the nightly app share it (`scripts/build-desktop-artifact.ts`).
    static let bundleID = "com.t3tools.t3code"
    static let protocolVersion = "2"
    static let protocolHeader = "x-t3-orchestration-protocol"

    enum Status: Equatable, Sendable {
        case running(origin: URL)
        case notRunning
        /// The server file names an address that is not this Mac. Waggle refuses it.
        case refused
    }

    /// `<base>/userdata`, where `<base>` is `$T3CODE_HOME` or `~/.t3`. A build in development with no
    /// `T3CODE_HOME` writes to `<base>/dev` instead, so that folder is looked at second.
    static func stateDirectories(homeDirectory: String, environment: [String: String]) -> [String] {
        if let raw = environment["T3CODE_HOME"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            let base = raw.hasPrefix("~/") ? homeDirectory + "/" + raw.dropFirst(2) : raw
            return [base + "/userdata"]
        }
        return [homeDirectory + "/.t3/userdata", homeDirectory + "/.t3/dev"]
    }

    /// Only an address on this Mac, as an origin with no path: `127.0.0.1`, `::1` or `localhost`,
    /// with a port, no login part.
    static func loopbackOrigin(_ raw: String) -> URL? {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")), ["127.0.0.1", "::1", "localhost"].contains(host),
              components.user == nil, components.password == nil,
              let port = components.port, (1...65535).contains(port) else { return nil }
        return URL(string: "\(scheme)://\(host.contains(":") ? "[\(host)]" : host):\(port)")
    }

    /// `server-runtime.json`: `{version, pid, host?, port, origin, startedAt}`.
    static func parseRuntimeFile(_ data: Data) -> (origin: String, pid: Int?)? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let origin = object["origin"] as? String else { return nil }
        return (origin, (object["pid"] as? Int))
    }

    static func serverStatus(
        homeDirectory: String, environment: [String: String], fileManager: FileManager = .default,
        isProcessAlive: (Int) -> Bool = { pid in kill(pid_t(pid), 0) == 0 || errno == EPERM }
    ) -> Status {
        var refused = false
        for directory in stateDirectories(homeDirectory: homeDirectory, environment: environment) {
            guard let data = fileManager.contents(atPath: directory + "/server-runtime.json"),
                  let runtime = parseRuntimeFile(data) else { continue }
            // The file stays behind when the server stops, so a dead process counts as not running.
            if let pid = runtime.pid, !isProcessAlive(pid) { continue }
            guard let origin = loopbackOrigin(runtime.origin) else { refused = true; continue }
            return .running(origin: origin)
        }
        return refused ? .refused : .notRunning
    }
}

/// Which agent the thread runs.
enum T3Agent: Sendable {
    case claude, codex

    /// The provider instance id (`packages/contracts/src/model.ts`).
    var instanceID: String { self == .claude ? "claudeAgent" : "codex" }
    /// `DEFAULT_MODEL_BY_PROVIDER` at the tag. Used only when the project names no model for this agent.
    var defaultModel: String { self == .claude ? "claude-fable-5-1" : "gpt-6-astra" }

    init(target: LaunchTarget) { self = target == .codexT3 ? .codex : .claude }
}

struct T3Project: Equatable, Sendable {
    var id: String
    var title: String
    var workspaceRoot: String
    var deleted = false
    var defaultInstanceID: String?
    var defaultModel: String?
}

struct T3LaunchRequest: Equatable, Sendable {
    var projectID: String
    var title: String
    var agent: T3Agent
    var model: String
    var prompt: String
    /// The project's own `defaultRuntimeMode`, or nil when it has none.
    var runtimeMode: String? = nil
}

enum T3Error: Error, Equatable {
    case notLoopback
    case http(Int)
    case rejected(String)
    case badResponse
    case timedOut
}

/// The calls Waggle makes to T3 Code's server. A fake stands in for it in every test.
protocol T3Serving: Sendable {
    func listProjects(origin: URL, token: String) async throws -> [T3Project]
    func createProject(origin: URL, token: String, title: String, workspaceRoot: String) async throws -> T3Project
    /// The project's own runtime mode setting (`server.getSettings`, `projectSettingsOverrides`), nil when it has none.
    func projectRuntimeMode(origin: URL, token: String, projectID: String) async throws -> String?
    func launchThread(origin: URL, token: String, request: T3LaunchRequest) async throws
}

/// Pure builders and parsers for the wire format.
enum T3Wire {
    static func createProjectBody(commandID: String, projectID: String, title: String, workspaceRoot: String) -> [String: Any] {
        ["type": "project.create", "commandId": commandID, "projectId": projectID, "title": title, "workspaceRoot": workspaceRoot]
    }

    /// `OrchestrationV2ThreadLaunchInput` (`packages/contracts/src/orchestrationV2.ts`).
    static func launchPayload(commandID: String, request: T3LaunchRequest) -> [String: Any] {
        [
            "commandId": commandID,
            "projectId": request.projectID,
            "title": request.title,
            "modelSelection": ["instanceId": request.agent.instanceID, "model": request.model],
            "runtimeMode": request.runtimeMode ?? defaultRuntimeMode,
            "interactionMode": "default",
            "workspaceStrategy": ["type": "root"],
            "initialMessage": ["text": request.prompt, "attachments": [Any]()],
        ]
    }

    static let launchTag = "orchestration.launchThread"
    static let settingsTag = "server.getSettings"

    /// Used only when the T3 project has no runtime mode of its own: the agent asks before it acts.
    static let defaultRuntimeMode = "approval-required"
    /// `RuntimeMode` (`packages/contracts/src/providerPolicy.ts`). Anything else is ignored.
    static let runtimeModes: Set<String> = ["approval-required", "auto-accept-edits", "auto", "full-access"]

    /// `projectSettingsOverrides[projectID].defaultRuntimeMode` from a `ServerSettings` value.
    static func runtimeMode(settings: Any?, projectID: String) -> String? {
        guard let root = settings as? [String: Any],
              let overrides = root["projectSettingsOverrides"] as? [String: Any],
              let entry = overrides[projectID] as? [String: Any],
              let mode = entry["defaultRuntimeMode"] as? String, runtimeModes.contains(mode) else { return nil }
        return mode
    }

    /// One Effect RPC request frame, JSON serialization, one frame per message.
    static func rpcFrame(id: String, tag: String, payload: [String: Any]) -> Data {
        let frame: [String: Any] = ["_tag": "Request", "id": id, "tag": tag, "payload": payload, "headers": [Any]()]
        return (try? JSONSerialization.data(withJSONObject: frame)) ?? Data()
    }

    enum Outcome: Equatable, Sendable {
        case success
        /// A success that carries the call's result, as JSON.
        case value(Data)
        case failure(String)
    }

    /// The answer to request `id`, or nil for any other frame (pings, other requests). A frame may be one
    /// message or an array of them.
    static func outcome(frame: Data, id: String) -> Outcome? {
        guard let root = try? JSONSerialization.jsonObject(with: frame) else { return nil }
        let messages = (root as? [[String: Any]]) ?? ((root as? [String: Any]).map { [$0] } ?? [])
        for message in messages {
            let tag = message["_tag"] as? String
            if tag == "Defect" { return .failure("defect") }
            guard tag == "Exit", "\(message["requestId"] ?? "")" == id, let exit = message["exit"] as? [String: Any] else { continue }
            if (exit["_tag"] as? String) == "Success" {
                if let value = exit["value"], JSONSerialization.isValidJSONObject(["v": value]),
                   let data = try? JSONSerialization.data(withJSONObject: ["v": value]) { return .value(data) }
                return .success
            }
            return .failure(failureText(exit))
        }
        return nil
    }

    private static func failureText(_ exit: [String: Any]) -> String {
        let cause = (exit["cause"] as? [[String: Any]])?.first
        if let error = cause?["error"] as? [String: Any] {
            return (error["message"] as? String) ?? (error["_tag"] as? String) ?? "failed"
        }
        return "failed"
    }

    static func parseProjects(_ data: Data) -> [T3Project]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let array = root["projects"] as? [[String: Any]] else { return nil }
        return array.compactMap(parseProject)
    }

    static func parseProject(_ object: [String: Any]) -> T3Project? {
        guard let id = object["id"] as? String, let root = object["workspaceRoot"] as? String else { return nil }
        let selection = object["defaultModelSelection"] as? [String: Any]
        return T3Project(
            id: id, title: (object["title"] as? String) ?? "", workspaceRoot: root,
            deleted: !(object["deletedAt"] is NSNull) && object["deletedAt"] != nil,
            defaultInstanceID: selection?["instanceId"] as? String, defaultModel: selection?["model"] as? String)
    }
}

/// One RPC call over a WebSocket. A fake stands in for it in every test.
protocol T3RPCSocket: Sendable {
    func call(url: URL, frame: Data, id: String, timeout: TimeInterval) async throws -> T3Wire.Outcome
}

/// The real socket: one `URLSessionWebSocketTask` per call, closed when the answer comes.
struct URLSessionRPCSocket: T3RPCSocket {
    func call(url: URL, frame: Data, id: String, timeout: TimeInterval) async throws -> T3Wire.Outcome {
        let task = URLSession(configuration: .ephemeral).webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
        return try await withThrowingTaskGroup(of: T3Wire.Outcome.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await task.send(.string(String(decoding: frame, as: UTF8.self)))
                    while true {
                        let message = try await task.receive()
                        let data: Data
                        switch message {
                        case .string(let text): data = Data(text.utf8)
                        case .data(let bytes): data = bytes
                        @unknown default: continue
                        }
                        if let outcome = T3Wire.outcome(frame: data, id: id) { return outcome }
                    }
                } onCancel: {
                    task.cancel(with: .normalClosure, reason: nil)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw T3Error.timedOut
            }
            defer { group.cancelAll(); task.cancel(with: .normalClosure, reason: nil) }
            guard let first = try await group.next() else { throw T3Error.badResponse }
            return first
        }
    }
}

/// The real server client. Every call checks the origin first: a call to an address that is not
/// on this Mac is refused before any request is made.
struct T3HTTPServer: T3Serving {
    var session: URLSession = .shared
    var socket: T3RPCSocket = URLSessionRPCSocket()
    var requestTimeout: TimeInterval = 10
    var launchTimeout: TimeInterval = 30
    var newID: @Sendable () -> String = { UUID().uuidString.lowercased() }

    private func guardOrigin(_ origin: URL) throws {
        guard T3Runtime.loopbackOrigin(origin.absoluteString) != nil else { throw T3Error.notLoopback }
    }

    private func send(
        origin: URL, path: String, method: String, token: String, body: [String: Any]? = nil
    ) async throws -> Data {
        try guardOrigin(origin)
        var request = URLRequest(url: origin.appendingPathComponent(path), timeoutInterval: requestTimeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(T3Runtime.protocolVersion, forHTTPHeaderField: T3Runtime.protocolHeader)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw T3Error.badResponse }
        guard (200..<300).contains(status) else { throw T3Error.http(status) }
        return data
    }

    func listProjects(origin: URL, token: String) async throws -> [T3Project] {
        let data = try await send(origin: origin, path: "/api/projects", method: "GET", token: token)
        guard let projects = T3Wire.parseProjects(data) else { throw T3Error.badResponse }
        return projects
    }

    func createProject(origin: URL, token: String, title: String, workspaceRoot: String) async throws -> T3Project {
        let body = T3Wire.createProjectBody(commandID: newID(), projectID: newID(), title: title, workspaceRoot: workspaceRoot)
        let data = try await send(origin: origin, path: "/api/projects/mutate", method: "POST", token: token, body: body)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let project = T3Wire.parseProject(object) else { throw T3Error.badResponse }
        return project
    }

    func projectRuntimeMode(origin: URL, token: String, projectID: String) async throws -> String? {
        switch try await rpc(origin: origin, token: token, tag: T3Wire.settingsTag, payload: [:]) {
        case .value(let data):
            let wrapper = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return T3Wire.runtimeMode(settings: wrapper?["v"], projectID: projectID)
        case .success: return nil
        case .failure(let message): throw T3Error.rejected(message)
        }
    }

    func launchThread(origin: URL, token: String, request: T3LaunchRequest) async throws {
        switch try await rpc(
            origin: origin, token: token, tag: T3Wire.launchTag,
            payload: T3Wire.launchPayload(commandID: newID(), request: request)) {
        case .success, .value: return
        case .failure(let message): throw T3Error.rejected(message)
        }
    }

    /// One RPC call: a WebSocket ticket over HTTP, then one request frame on `/ws`.
    private func rpc(origin: URL, token: String, tag: String, payload: [String: Any]) async throws -> T3Wire.Outcome {
        let ticketData = try await send(origin: origin, path: "/api/auth/websocket-ticket", method: "POST", token: token)
        guard let object = (try? JSONSerialization.jsonObject(with: ticketData)) as? [String: Any],
              let ticket = object["ticket"] as? String, !ticket.isEmpty else { throw T3Error.badResponse }
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)
        components?.scheme = origin.scheme == "https" ? "wss" : "ws"
        components?.path = "/ws"
        components?.queryItems = [
            URLQueryItem(name: "orchestrationProtocol", value: T3Runtime.protocolVersion),
            URLQueryItem(name: "wsTicket", value: ticket),
        ]
        guard let url = components?.url else { throw T3Error.badResponse }
        let id = newID()
        let frame = T3Wire.rpcFrame(id: id, tag: tag, payload: payload)
        return try await socket.call(url: url, frame: frame, id: id, timeout: launchTimeout)
    }
}

/// What a T3 Code launch ended with.
enum T3LaunchResult: Equatable, Sendable {
    case started
    /// One plain line for the sheet. `copyPrompt` is true when the prompt must go on the clipboard.
    case failed(String, copyPrompt: Bool)
}

/// Finds or makes the project for the folder, starts the thread with the prompt, then brings T3 Code
/// forward on the folder. Any failed step falls back to `t3 app <folder>` and the clipboard.
struct T3Launcher: Sendable {
    let secrets: SecretStoring
    let meta: T3MetaStoring
    let server: T3Serving
    let runner: CLIRunning
    let homeDirectory: String
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var now: @Sendable () -> Date = { Date() }
    var isProcessAlive: @Sendable (Int) -> Bool = { pid in kill(pid_t(pid), 0) == 0 || errno == EPERM }

    static let fallbackWithApp = "Waggle could not start the thread. T3 Code is open on the folder and the prompt is on your clipboard."
    static let fallbackNoApp = "Waggle could not start the thread. The prompt is on your clipboard. Open T3 Code and paste it."
    static let pasteOnly = "Waggle cannot limit access in this T3 Code version. T3 Code is open on the folder and the prompt is on your clipboard. Paste it to start."
    static let notShown = "T3 Code started the thread, but could not bring it forward. Look for it in T3 Code."

    func launch(target: LaunchTarget, folder: String, topic: String, prompt: String, searchPath: String) async -> T3LaunchResult {
        // A `t3` command that cannot limit a token to a scope never gets a token from Waggle: open and paste.
        if let cli = T3Command.findCLI(searchPath: searchPath, homeDirectory: homeDirectory),
           !(await T3Command.probeScope(runner: runner, cli: cli, searchPath: searchPath)) {
            let opened = await openApp(folder: folder, searchPath: searchPath)
            return .failed(opened ? Self.pasteOnly : Self.fallbackNoApp, copyPrompt: true)
        }
        if await startThread(target: target, folder: folder, topic: topic, prompt: prompt) {
            return await openApp(folder: folder, searchPath: searchPath)
                ? .started : .failed(Self.notShown, copyPrompt: false)
        }
        let opened = await openApp(folder: folder, searchPath: searchPath)
        return .failed(opened ? Self.fallbackWithApp : Self.fallbackNoApp, copyPrompt: true)
    }

    /// Steps 1 to 3. False on any failure; nothing is retried, because a launch that got lost on the
    /// way back could otherwise start two threads.
    private func startThread(target: LaunchTarget, folder: String, topic: String, prompt: String) async -> Bool {
        guard let expiry = meta.expiry, expiry > now(), let token = secrets.load() else { return false }
        guard case .running(let origin) = T3Runtime.serverStatus(
            homeDirectory: homeDirectory, environment: environment, isProcessAlive: isProcessAlive) else { return false }
        let agent = T3Agent(target: target)
        do {
            let wanted = SupersetCommand.normalizedPath(folder)
            let projects = try await server.listProjects(origin: origin, token: token)
            let project: T3Project
            if let found = projects.first(where: { !$0.deleted && SupersetCommand.normalizedPath($0.workspaceRoot) == wanted }) {
                project = found
            } else {
                let name = URL(fileURLWithPath: wanted).lastPathComponent
                project = try await server.createProject(
                    origin: origin, token: token, title: name.isEmpty ? "Project" : name, workspaceRoot: wanted)
            }
            // A failed read counts as "the project has none": the safe mode is used, the launch goes on.
            let mode = try? await server.projectRuntimeMode(origin: origin, token: token, projectID: project.id)
            let model = project.defaultInstanceID == agent.instanceID ? (project.defaultModel ?? agent.defaultModel) : agent.defaultModel
            try await server.launchThread(
                origin: origin, token: token,
                request: T3LaunchRequest(
                    projectID: project.id, title: SupersetCommand.shortName(topic: topic), agent: agent, model: model, prompt: prompt, runtimeMode: mode))
            return true
        } catch {
            return false
        }
    }

    private func openApp(folder: String, searchPath: String) async -> Bool {
        guard let cli = T3Command.findCLI(searchPath: searchPath, homeDirectory: homeDirectory) else { return false }
        let result = await runner.run(
            executable: cli, arguments: T3Command.appArguments(folder: folder), searchPath: searchPath, timeout: T3Command.appTimeout)
        return result.succeeded
    }
}
