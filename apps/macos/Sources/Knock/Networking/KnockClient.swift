import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A Swift-concurrency client for the Knock daemon's unix socket, JSON-RPC 2.0,
/// newline-delimited protocol (docs/protocol-mvp.md "Socket RPC").
///
/// Owns one connection at a time. `start()` begins a reconnect loop with
/// backoff `backoffSchedule` (default 1s, 2s, 5s, then holds at 5s).
/// `events` streams `Event` notifications pushed by the daemon; a fresh
/// subscription is needed after every reconnect (callers should call
/// `subscribeEvents()` again when `connectionStates` yields `.connected`).
actor KnockClient {
    enum ConnectionState: Equatable, Sendable {
        case connecting
        case connected
        case disconnected
    }

    enum ClientError: Error, Equatable, Sendable {
        case pathTooLong
        case connectFailed
        case notConnected
        case connectionClosed
        case malformedResponse
        case timeout
    }

    /// Every request is bounded (AC: "put a timeout on every client
    /// request" - a hung `await` on an unanswered request was how a stuck
    /// pending reply blocked reconnect forever, see `SendCoordinator`'s
    /// Choices ledger entry). `reply.submit` overrides this when it carries
    /// captures, since a multi-megabyte base64 payload legitimately needs
    /// longer than a plain RPC. `events.subscribe`'s own request still
    /// resolves promptly (it only ever answers `{}`); the long-lived part is
    /// the separate `events` stream this timeout does not touch.
    static let defaultRequestTimeout: Duration = .seconds(10)

    private let socketPath: String
    private let backoffSchedule: [TimeInterval]
    /// Starts `knock daemon` on demand when the socket is unreachable. Injected
    /// so tests can assert the trigger without spawning a real daemon.
    private let startDaemon: @Sendable () -> Void

    private var fd: Int32 = -1
    private var fileHandle: FileHandle?
    private var readBuffer = Data()
    /// Identifies the open connection, so a late chunk or close from an old one is ignored.
    private var connectionGeneration = 0
    private var inboxContinuation: AsyncStream<Data>.Continuation?
    /// How far into `readBuffer` a newline was already searched for. A
    /// multi-megabyte response arrives in many reads; searching only the new
    /// bytes keeps framing linear. Rescanning the whole buffer on every read
    /// was quadratic and made a 17.8 MB reply time out (operator, 4 Oct).
    private var scannedCount = 0

    /// Decoded capture images by "<capture id>|<kind>" (PERF-2), see `captureImageData`.
    private var captureImageCache: [String: Data] = [:]

    private var nextId = 1
    private var pending: [Int: (Result<Data, Error>) -> Void] = [:]

    private var connectTask: Task<Void, Never>?
    private var closeContinuation: CheckedContinuation<Void, Never>?
    private var reconnectAttempt = 0
    private var stopped = true

    private let stateContinuation: AsyncStream<ConnectionState>.Continuation
    /// Freely observable from any context: it is a `let` of a `Sendable`
    /// stream, set once in `init` and never mutated, so callers should not
    /// need to hop onto this actor just to start iterating it.
    nonisolated let connectionStates: AsyncStream<ConnectionState>

    private let eventContinuation: AsyncStream<Event>.Continuation
    nonisolated let events: AsyncStream<Event>

    init(
        socketPath: String,
        backoffSchedule: [TimeInterval] = [1, 2, 5],
        startDaemon: @escaping @Sendable () -> Void = { ServiceControl.startDaemon() }
    ) {
        self.socketPath = socketPath
        self.backoffSchedule = backoffSchedule
        self.startDaemon = startDaemon

        var stateContinuation: AsyncStream<ConnectionState>.Continuation!
        self.connectionStates = AsyncStream { continuation in
            stateContinuation = continuation
        }
        self.stateContinuation = stateContinuation

        var eventContinuation: AsyncStream<Event>.Continuation!
        self.events = AsyncStream { continuation in
            eventContinuation = continuation
        }
        self.eventContinuation = eventContinuation
    }

    // MARK: - Lifecycle

    func start() {
        guard connectTask == nil else { return }
        stopped = false
        connectTask = Task { [weak self] in
            await self?.runConnectionLoop()
        }
    }

    func stop() {
        stopped = true
        connectTask?.cancel()
        connectTask = nil
        closeConnection()
        stateContinuation.yield(.disconnected)
    }

    private func runConnectionLoop() async {
        var startedOnDemand = false
        while !stopped, !Task.isCancelled {
            stateContinuation.yield(.connecting)
            do {
                try openConnection()
                startedOnDemand = false
            } catch {
                // Start the daemon once per disconnected episode, then retry
                // fast for up to 3s before falling back to the slow schedule.
                if !startedOnDemand {
                    startedOnDemand = true
                    startDaemon()
                    let deadline = Date().addingTimeInterval(3)
                    while !stopped, !Task.isCancelled, Date() < deadline {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        do {
                            try openConnection()
                            break
                        } catch {
                            // Keep retrying until the deadline.
                        }
                    }
                }
            }
            if stopped || Task.isCancelled { break }
            if fd >= 0 {
                stateContinuation.yield(.connected)
                reconnectAttempt = 0
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self.closeContinuation = continuation
                }
            }
            if stopped || Task.isCancelled { break }
            stateContinuation.yield(.disconnected)
            let index = min(reconnectAttempt, backoffSchedule.count - 1)
            let delay = backoffSchedule[index]
            reconnectAttempt += 1
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    // MARK: - Connection

    private func openConnection() throws {
        let newFD = try Self.openSocket(path: socketPath)
        fd = newFD
        let handle = FileHandle(fileDescriptor: newFD, closeOnDealloc: true)
        fileHandle = handle
        // One ordered inbox per connection. A separate `Task` per chunk can run out of
        // order, and a big `cases.list` answer then arrives garbled: the request times out
        // and the queue stays stale (HAIL-120). A stream keeps the chunks in order.
        connectionGeneration += 1
        let generation = connectionGeneration
        let (inbox, inboxContinuation) = AsyncStream<Data>.makeStream()
        self.inboxContinuation = inboxContinuation
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                inboxContinuation.finish()
            } else {
                inboxContinuation.yield(data)
            }
        }
        Task { [weak self] in
            for await data in inbox {
                guard let self else { return }
                await self.handleIncoming(data, generation: generation)
            }
            await self?.handleConnectionClosed(generation: generation)
        }
    }

    private func closeConnection() {
        fileHandle?.readabilityHandler = nil
        inboxContinuation?.finish()
        inboxContinuation = nil
        connectionGeneration += 1
        fileHandle = nil
        fd = -1
        readBuffer.removeAll()
        scannedCount = 0
        closeContinuation?.resume()
        closeContinuation = nil
    }

    private func handleConnectionClosed(generation: Int) {
        guard generation == connectionGeneration else { return }
        fileHandle = nil
        fd = -1
        readBuffer.removeAll()
        scannedCount = 0
        let failedPending = pending
        pending.removeAll()
        for callback in failedPending.values {
            callback(.failure(ClientError.connectionClosed))
        }
        closeContinuation?.resume()
        closeContinuation = nil
    }

    private static func openSocket(path: String) throws -> Int32 {
        let sockFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sockFD >= 0 else { throw ClientError.connectFailed }
        // A write to a socket the daemon already closed must fail with EPIPE,
        // not raise SIGPIPE, which terminates the whole app (seen as "signal
        // code 13" when a test's server went away before a write).
        var noSigPipe: Int32 = 1
        setsockopt(sockFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        let pathBytes = Array(path.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathBytes.count <= maxLen else {
            close(sockFD)
            throw ClientError.pathTooLong
        }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            for (i, byte) in pathBytes.enumerated() {
                base[i] = byte
            }
            base[pathBytes.count] = 0
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(sockFD, sa, len)
            }
        }
        guard rc == 0 else {
            close(sockFD)
            throw ClientError.connectFailed
        }
        return sockFD
    }

    // MARK: - Reading

    private func handleIncoming(_ data: Data, generation: Int) {
        guard generation == connectionGeneration else { return }
        readBuffer.append(data)
        while let newlineIndex = readBuffer[(readBuffer.startIndex + scannedCount)...].firstIndex(of: 0x0A) {
            let lineData = readBuffer.subdata(in: readBuffer.startIndex..<newlineIndex)
            readBuffer.removeSubrange(readBuffer.startIndex...newlineIndex)
            scannedCount = 0
            if !lineData.isEmpty {
                handleLine(lineData)
            }
        }
        scannedCount = readBuffer.count
    }

    private func handleLine(_ data: Data) {
        guard let peek = try? JSONDecoder().decode(JSONRPCLinePeek.self, from: data) else { return }
        if let id = peek.id, peek.method == nil {
            if let callback = pending.removeValue(forKey: id) {
                callback(.success(data))
            }
            return
        }
        if peek.method == "event" {
            if let notification = try? JSONDecoder().decode(JSONRPCNotification<Event>.self, from: data) {
                eventContinuation.yield(notification.params)
            }
        }
    }

    // MARK: - Writing

    private func sendLine(_ data: Data) throws {
        guard fd >= 0 else { throw ClientError.notConnected }
        var payload = data
        payload.append(0x0A)
        let currentFD = fd
        let sent: Int = payload.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            var written = 0
            while written < raw.count {
                let n = write(currentFD, base + written, raw.count - written)
                if n <= 0 { return -1 }
                written += n
            }
            return written
        }
        guard sent >= 0 else { throw ClientError.connectionClosed }
    }

    // MARK: - RPC

    func call<Params: Encodable, Res: Decodable & Sendable>(
        _ method: String, params: Params, timeout: Duration = KnockClient.defaultRequestTimeout
    ) async throws -> Res {
        let id = nextId
        nextId += 1
        let request = JSONRPCRequest(id: id, method: method, params: params)
        let data = try JSONEncoder().encode(request)

        // The timer fails the pending request itself (the same callback a
        // response or a dropped connection uses), so the awaiting
        // continuation always resumes exactly once. A task-group race does
        // not work here: the group waits for the response child, whose
        // continuation nothing would ever resume, so a timeout still hung.
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.failPending(id: id, error: ClientError.timeout)
        }
        defer { timer.cancel() }
        return try await awaitResponse(id: id, sending: data)
    }

    /// Resumes and forgets request `id` with `error`, if it is still waiting.
    private func failPending(id: Int, error: Error) {
        if let callback = pending.removeValue(forKey: id) {
            callback(.failure(error))
        }
    }

    /// Registers `id`'s response callback and sends the request line, both
    /// synchronously within this continuation's setup - never split across
    /// an `await`, so a response arriving the instant after `sendLine`
    /// cannot race ahead of `pending[id]` being set (the actor's single
    /// executor guarantees nothing else runs in between).
    private func awaitResponse<Res: Decodable & Sendable>(id: Int, sending data: Data) async throws -> Res {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Res, Error>) in
            pending[id] = { result in
                switch result {
                case .success(let lineData):
                    do {
                        let decoded = try JSONDecoder().decode(JSONRPCResponseEnvelope<Res>.self, from: lineData)
                        if let error = decoded.error {
                            continuation.resume(throwing: error)
                        } else if let value = decoded.result {
                            continuation.resume(returning: value)
                        } else {
                            continuation.resume(throwing: ClientError.malformedResponse)
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            do {
                try sendLine(data)
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - Typed app/CLI RPC methods (docs/protocol-mvp.md "Socket RPC")

extension KnockClient {
    func casesList(status: CaseStatus? = nil) async throws -> [Case] {
        try await call("cases.list", params: CasesListParams(status: status))
    }

    func casesGet(id: String) async throws -> CaseDetail {
        try await call("cases.get", params: CasesGetParams(id: id))
    }

    func artifactPath(caseId: String, revision: Int) async throws -> ArtifactPathResult {
        try await call("artifact.path", params: ArtifactPathParams(caseId: caseId, revision: revision))
    }

    /// One capture's image, base64 as stored (PERF-2: `cases.get` carries none).
    func captureImage(captureId: String, which: CaptureImageKind) async throws -> String {
        let result: CaptureImageResult = try await call(
            "capture.image", params: CaptureImageParams(captureId: captureId, which: which),
            timeout: .seconds(30))
        return result.pngBase64
    }

    /// The decoded bytes of one capture image, fetched on first use and kept in
    /// memory per capture id and kind (PERF-2). `nil` when the daemon has no such
    /// capture or the call fails; a failure is not cached, so a later call retries.
    func captureImageData(captureId: String, which: CaptureImageKind) async -> Data? {
        let key = "\(captureId)|\(which.rawValue)"
        if let cached = captureImageCache[key] { return cached }
        guard let base64 = try? await captureImage(captureId: captureId, which: which),
              let data = Data(base64Encoded: base64), !data.isEmpty else { return nil }
        captureImageCache[key] = data
        return data
    }

    /// `timeout` defaults to 30s when `captures` is non-empty (a
    /// multi-megabyte base64 payload legitimately takes longer than a plain
    /// RPC's 10s), else the usual default. A caller (`SendCoordinator`'s
    /// reconnect resubmit) may still pass a tighter override.
    func replySubmit(
        caseId: String,
        idempotencyKey: String,
        choice: String?,
        optionsSet: String? = nil,
        message: String?,
        comments: [Comment],
        captures: [Capture],
        intent: ReplyIntent = .decision,
        choices: [String]? = nil,
        answers: [PointAnswer]? = nil,
        itemAnswers: [ItemAnswer]? = nil,
        format: ReplyFormat? = nil,
        edit: ReplyEditRef? = nil,
        leaning: [String]? = nil,
        ruledOut: [String]? = nil,
        attachments: [ReplyAttachmentInput]? = nil,
        timeout: Duration? = nil
    ) async throws -> Reply {
        try await call(
            "reply.submit",
            params: ReplySubmitParams(
                caseId: caseId,
                idempotencyKey: idempotencyKey,
                choice: choice,
                optionsSet: optionsSet,
                message: message,
                comments: comments,
                captures: captures,
                intent: intent,
                choices: choices,
                answers: answers,
                itemAnswers: itemAnswers,
                format: format,
                edit: edit,
                leaning: leaning,
                ruledOut: ruledOut,
                attachments: attachments
            ),
            timeout: timeout ?? (captures.isEmpty ? KnockClient.defaultRequestTimeout : .seconds(30))
        )
    }

    /// WAG-410: marks a failed reply handed over once "Continue in a new session" started one.
    func replyHandOver(replyId: String) async throws -> Reply {
        try await call("reply.hand_over", params: ReplyHandOverParams(replyId: replyId))
    }

    func replyRetry(replyId: String) async throws -> Reply {
        try await call("reply.retry", params: ReplyRetryParams(replyId: replyId))
    }

    /// "Change answer" while the reply is still queued (HAIL-34): replaces
    /// its choice/message/comments/captures in place, under the same id.
    /// Throws once the daemon reports the reply is no longer queued
    /// (delivered or failed) - the daemon's own error message names which.
    func replyReplace(
        replyId: String,
        choice: String?,
        optionsSet: String? = nil,
        message: String?,
        comments: [Comment],
        captures: [Capture],
        choices: [String]? = nil,
        answers: [PointAnswer]? = nil,
        itemAnswers: [ItemAnswer]? = nil,
        edit: ReplyEditRef? = nil,
        attachments: [ReplyAttachmentInput]? = nil
    ) async throws -> Reply {
        try await call(
            "reply.replace",
            params: ReplyReplaceParams(
                replyId: replyId,
                choice: choice,
                optionsSet: optionsSet,
                message: message,
                comments: comments,
                captures: captures,
                choices: choices,
                answers: answers,
                itemAnswers: itemAnswers,
                edit: edit,
                attachments: attachments
            )
        )
    }

    /// Stores the person's edited markdown as the next revision of the case (HAIL-168).
    func revisionAddByHuman(caseId: String, baseRevision: Int, markdown: String) async throws -> Revision {
        try await call(
            "revision.add_by_human",
            params: RevisionAddByHumanParams(caseId: caseId, baseRevision: baseRevision, markdown: markdown)
        )
    }

    /// Dismisses a case (HAIL-32): the daemon resolves it, remembering its
    /// prior status for a later `caseRestore`.
    func caseDismiss(caseId: String) async throws -> Case {
        try await call("case.dismiss", params: CaseDismissParams(caseId: caseId))
    }

    /// The Undo half of `caseDismiss` (HAIL-32): clears `dismissedAt` and
    /// restores the case to whichever status it held right before the dismiss.
    func caseRestore(caseId: String) async throws -> Case {
        try await call("case.restore", params: CaseRestoreParams(caseId: caseId))
    }

    /// Sends the events.subscribe request. Call again after every reconnect;
    /// the daemon has no memory of a subscription from a dropped connection.
    func subscribeEvents() async throws {
        let _: EmptyResult = try await call("events.subscribe", params: EmptyParams())
    }

    func serviceStatus() async throws -> ServiceStatus {
        try await call("service.status", params: EmptyParams())
    }

    /// The daemon's live-session projection (HAIL-46): the Connection screen
    /// reads this to show the same sessions `knock doctor` prints.
    func sessionsList() async throws -> [SessionInfo] {
        try await call("sessions.list", params: EmptyParams())
    }

    /// Nudges the session that owns `caseId` (HAIL-76): the daemon pushes one
    /// line into the agent's inbox so it calls `knock_check`.
    func sessionNudge(caseId: String) async throws -> NudgeResult {
        try await call("session.nudge", params: NudgeParams(caseId: caseId))
    }

    /// Sends one prompt into a live Claude Code session (HAIL-169), as if typed.
    func sessionSendPrompt(sessionId: String, text: String) async throws -> SendPromptResult {
        try await call("session.send_prompt", params: SendPromptParams(sessionId: sessionId, text: text))
    }

    /// Asks the daemon to exit cleanly so the next on-demand start runs the
    /// newer bundled binary (KNOCK-21 handoff). The daemon replies immediately
    /// and then drains in-flight reply deliveries before it stops.
    func serviceRestart() async throws {
        let _: EmptyResult = try await call("service.restart", params: EmptyParams())
    }

    /// Reports one usage event the app owns (KNOCK-19, HAIL-83). Best-effort:
    /// callers ignore a failed report (an old daemon rejects a new event); it
    /// never blocks or fails the action it describes.
    func usageRecord(_ record: UsageRecord) async throws {
        let _: EmptyResult = try await call("usage.record", params: record)
    }

    func usageRecord(event: UsageEvent, source: CaseOpenSource? = nil) async throws {
        try await usageRecord(UsageRecord(event, source: source?.rawValue))
    }

    /// The Artifacts page's preset (HAIL-100). The daemon stores it and reads
    /// "visual" when unset.
    func artifactPreset() async throws -> ArtifactPreset {
        try await settingsGet("artifactPreset")
    }

    @discardableResult
    func setArtifactPreset(_ preset: ArtifactPreset) async throws -> ArtifactPreset {
        try await settingsSet("artifactPreset", preset)
    }

    /// The default design kit (HAIL-166). The daemon is its only writer.
    func designKit() async throws -> DesignKitResult {
        try await call("design_kit.get", params: EmptyParams())
    }

    func setDesignKit(_ change: DesignKitChange) async throws -> DesignKitResult {
        try await call("design_kit.set", params: change)
    }

    func undoDesignKit() async throws -> DesignKitResult {
        try await call("design_kit.undo", params: EmptyParams())
    }

    /// Ask preferences (HAIL-101). Unset reads as the daemon's defaults.
    func askTopics() async throws -> AskTopics { try await settingsGet("askTopics") }
    func askFrequency() async throws -> AskFrequency { try await settingsGet("askFrequency") }
    func askDetail() async throws -> AskDetail { try await settingsGet("askDetail") }
    func askReach() async throws -> AskReach { try await settingsGet("askReach") }
    func askWords() async throws -> AskWords { try await settingsGet("askWords") }
    func askLearn() async throws -> AskLearn { try await settingsGet("askLearn") }
    func askAfterDecide() async throws -> AskAfterDecide { try await settingsGet("askAfterDecide") }

    /// "Let the agent decide small things" (WAG-412). Off until the person turns it on.
    func askLess() async throws -> AskLess { try await settingsGet("askLess") }

    @discardableResult
    func setAskLess(_ value: AskLess) async throws -> AskLess { try await settingsSet("askLess", value.wire) }

    /// The cases a rule decided since `since` (WAG-412), newest first.
    func casesAutoDecided(since: Date? = nil) async throws -> [Case] {
        try await call("cases.auto_decided", params: CasesAutoDecidedParams(since: since.map(KnockDateFormat.string(from:))))
    }

    /// "Change my mind" (WAG-412): the case is an open ask again.
    func caseChangeMind(caseId: String) async throws -> Case {
        try await call("case.change_mind", params: CaseChangeMindParams(caseId: caseId))
    }

    /// The text the daemon generates from the three preferences and gives
    /// agents (read-only: the daemon is the one place that writes it).
    func askText() async throws -> String { try await settingsGet("askText") }

    @discardableResult
    func setAskTopics(_ value: AskTopics) async throws -> AskTopics { try await settingsSet("askTopics", value) }
    @discardableResult
    func setAskFrequency(_ value: AskFrequency) async throws -> AskFrequency { try await settingsSet("askFrequency", value) }
    @discardableResult
    func setAskDetail(_ value: AskDetail) async throws -> AskDetail { try await settingsSet("askDetail", value) }
    @discardableResult
    func setAskReach(_ value: AskReach) async throws -> AskReach { try await settingsSet("askReach", value) }
    @discardableResult
    func setAskWords(_ value: AskWords) async throws -> AskWords { try await settingsSet("askWords", value) }
    @discardableResult
    func setAskLearn(_ value: AskLearn) async throws -> AskLearn { try await settingsSet("askLearn", value) }
    @discardableResult
    func setAskAfterDecide(_ value: AskAfterDecide) async throws -> AskAfterDecide { try await settingsSet("askAfterDecide", value) }

    /// "Catch questions in the terminal" (WAG-265). An older daemon has no such key: that reads as on.
    func catchQuestions() async throws -> CatchQuestions { try await settingsGet("catchQuestions") }
    @discardableResult
    func setCatchQuestions(_ value: CatchQuestions) async throws -> CatchQuestions { try await settingsSet("catchQuestions", value) }

    private func settingsGet<Value: Decodable & Sendable>(_ key: String) async throws -> Value {
        let result: SettingsResult<Value> = try await call("settings.get", params: SettingsGetParams(key: key))
        return result.value
    }

    private func settingsSet<Value: Codable & Sendable>(_ key: String, _ value: Value) async throws -> Value {
        let result: SettingsResult<Value> = try await call("settings.set", params: SettingsSetParams(key: key, value: value))
        return result.value
    }

    // MARK: Chat connectors (HAIL-144)

    func connectorsStatus() async throws -> ConnectorsStatusResult {
        try await call("connectors.status", params: EmptyParams())
    }

    /// Asks Telegram whether the token is a real bot; the daemon keeps a good token in the Keychain.
    func telegramCheckToken(_ token: String) async throws -> TelegramStatus {
        try await call("connectors.telegram.check_token", params: TelegramCheckTokenParams(token: token))
    }

    func telegramStartPairing() async throws -> TelegramStatus {
        try await call("connectors.telegram.start_pairing", params: EmptyParams())
    }

    func telegramSendTest() async throws {
        let _: ConnectorOkResult = try await call("connectors.telegram.send_test", params: EmptyParams())
    }

    func telegramDisconnect() async throws -> TelegramStatus {
        try await call("connectors.telegram.disconnect", params: EmptyParams())
    }

    // MARK: Slack (HAIL-145)

    /// Checks both tokens (auth.test, a Socket Mode connection); the daemon keeps good ones in the Keychain.
    func slackCheckTokens(app: String, bot: String) async throws -> SlackStatus {
        try await call("connectors.slack.check_tokens", params: SlackCheckTokensParams(appToken: app, botToken: bot))
    }

    /// Reads the app id from the bot token alone, so the app's own page can be linked early. Saves nothing.
    func slackLookUpApp(bot: String) async throws -> SlackStatus {
        try await call("connectors.slack.look_up_app", params: SlackLookUpAppParams(botToken: bot))
    }

    func slackStartPairing() async throws -> SlackStatus {
        try await call("connectors.slack.start_pairing", params: EmptyParams())
    }

    func slackSendTest() async throws {
        let _: ConnectorOkResult = try await call("connectors.slack.send_test", params: EmptyParams())
    }

    func slackDisconnect() async throws -> SlackStatus {
        try await call("connectors.slack.disconnect", params: EmptyParams())
    }

    // MARK: Sharing a case (WAG-387)

    /// Reads the saved state. Makes no network call in the daemon.
    func sharingGet(caseId: String? = nil) async throws -> SharingState {
        try await call("sharing.get", params: SharingGetParams(caseId: caseId))
    }

    func sharingSetEnabled(_ enabled: Bool) async throws -> SharingState {
        try await call("sharing.set_enabled", params: SharingSetEnabledParams(enabled: enabled))
    }

    func sharingStart(caseId: String, mode: SharingMode, emails: [String]) async throws -> SharingState {
        try await call("sharing.start", params: SharingStartParams(caseId: caseId, mode: mode, emails: emails), timeout: .seconds(60))
    }

    func sharingStop(caseId: String) async throws -> SharingState {
        try await call("sharing.stop", params: SharingCaseParams(caseId: caseId), timeout: .seconds(60))
    }

    /// Uploads rounds that are not up yet and fetches the team's new comments.
    func sharingUpdate(caseId: String, mode: SharingMode, emails: [String]?) async throws -> SharingState {
        try await call("sharing.update", params: SharingUpdateParams(caseId: caseId, mode: mode, emails: emails), timeout: .seconds(60))
    }

    /// The one-time link that opens the shared page signed in as the owner.
    func sharingOpenPage(caseId: String) async throws -> String {
        let r: SharingOpenPageResult = try await call("sharing.open_page", params: SharingCaseParams(caseId: caseId), timeout: .seconds(60))
        return r.url
    }

    // MARK: The comment loop (WAG-394)

    func sharingReply(caseId: String, parentId: String, body: String) async throws -> SharingState {
        try await call("sharing.reply", params: SharingReplyParams(caseId: caseId, parentId: parentId, body: body), timeout: .seconds(60))
    }

    func sharingComment(caseId: String, body: String) async throws -> SharingState {
        try await call("sharing.comment", params: SharingCommentParams(caseId: caseId, body: body), timeout: .seconds(60))
    }

    func sharingResolve(caseId: String, commentId: String, resolved: Bool) async throws -> SharingState {
        try await call("sharing.resolve", params: SharingResolveParams(caseId: caseId, commentId: commentId, resolved: resolved), timeout: .seconds(60))
    }

    func sharingCloseComments(caseId: String, closed: Bool) async throws -> SharingState {
        try await call("sharing.close_comments", params: SharingCloseCommentsParams(caseId: caseId, closed: closed), timeout: .seconds(60))
    }

    /// WAG-401: the shared page shows the case as open while the owner changes the answer, and decided again on cancel.
    func sharingReopen(caseId: String, reopened: Bool) async throws -> SharingState {
        try await call("sharing.reopen", params: SharingReopenParams(caseId: caseId, reopened: reopened), timeout: .seconds(60))
    }

    /// WAG-401: the late comments went to the agent's session.
    func sharingMarkLateGiven(caseId: String) async throws -> SharingState {
        try await call("sharing.mark_late_given", params: SharingCaseParams(caseId: caseId))
    }

    func sharingMarkSeen(caseId: String) async throws -> [UnreadCase] {
        let r: SharingUnreadResult = try await call("sharing.mark_seen", params: SharingCaseParams(caseId: caseId))
        return r.cases
    }

    func sharingUnread() async throws -> [UnreadCase] {
        let r: SharingUnreadResult = try await call("sharing.unread", params: EmptyParams())
        return r.cases
    }

    func sharingTakeNotifications() async throws -> [TeamCommentNotice] {
        let r: SharingNotificationsResult = try await call("sharing.take_notifications", params: EmptyParams())
        return r.items
    }

    // MARK: Account (WAG-392)

    func accountGet() async throws -> AccountState { try await call("account.get", params: EmptyParams()) }
    func accountConnectStart() async throws -> AccountState { try await call("account.connect_start", params: EmptyParams(), timeout: .seconds(30)) }
    func accountConnectCancel() async throws -> AccountState { try await call("account.connect_cancel", params: EmptyParams()) }
    func accountSignOut() async throws -> AccountState { try await call("account.sign_out", params: EmptyParams(), timeout: .seconds(30)) }
    func accountShares() async throws -> AccountSharesResult { try await call("account.shares", params: EmptyParams(), timeout: .seconds(30)) }
    func accountStopShare(relayId: String) async throws -> AccountSharesResult {
        try await call("account.stop_share", params: AccountStopShareParams(relayId: relayId), timeout: .seconds(60))
    }

    func sharingRefresh(caseId: String) async throws -> SharingState {
        try await call("sharing.refresh", params: SharingCaseParams(caseId: caseId), timeout: .seconds(60))
    }

    /// The Data & privacy page's "Answered asks" row (HAIL-52): the count and
    /// on-disk byte size of every resolved case.
    func casesResolvedStats() async throws -> CasesResolvedStatsResult {
        try await call("cases.resolved_stats", params: EmptyParams())
    }

    /// "Clear answered…" (HAIL-52): deletes every resolved case and its
    /// staged artifacts. Never a case that still needs the human or is
    /// waiting on the agent.
    func casesPurgeResolved() async throws -> CasesPurgeResolvedResult {
        try await call("cases.purge_resolved", params: EmptyParams())
    }
}

// MARK: - Socket path resolution

extension KnockClient {
    /// docs/protocol-mvp.md "Components": data root is
    /// `~/Library/Application Support/Knock/`, override with `KNOCK_HOME`
    /// (tests always set it).
    static func defaultDataRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let home = environment["KNOCK_HOME"], !home.isEmpty {
            return home
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Knock", isDirectory: true)
            .path
    }

    /// The socket lives at `<data root>/knock.sock`.
    static func defaultSocketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        (defaultDataRoot(environment: environment) as NSString).appendingPathComponent("knock.sock")
    }
}
