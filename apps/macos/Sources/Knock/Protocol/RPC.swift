import Foundation

// JSON-RPC 2.0 envelope types. One JSON object per line, newline-delimited,
// over the unix socket (docs/protocol-mvp.md "Socket RPC").

struct JSONRPCRequest<Params: Encodable>: Encodable {
    var jsonrpc = "2.0"
    var id: Int
    var method: String
    var params: Params
}

struct JSONRPCErrorPayload: Decodable, Error, LocalizedError, Equatable {
    let code: Int
    let message: String
    /// The daemon's `error.data.message`: the real cause behind a bare "Internal error" (WAG-358).
    var cause: String? = nil
    var errorDescription: String? { message }

    private enum CodingKeys: String, CodingKey { case code, message, data }
    private struct Data: Decodable { let message: String? }

    init(code: Int, message: String, cause: String? = nil) {
        self.code = code
        self.message = message
        self.cause = cause
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(Int.self, forKey: .code)
        message = try c.decode(String.self, forKey: .message)
        cause = (try? c.decodeIfPresent(Data.self, forKey: .data))?.message
    }
}

struct JSONRPCResponseEnvelope<Result: Decodable>: Decodable {
    var jsonrpc: String?
    var id: Int?
    var result: Result?
    var error: JSONRPCErrorPayload?
}

// A pushed notification: no "id", a "method", and its params.
// Choice: the wire framing for events.subscribe's stream is not pinned down
// by docs/protocol-mvp.md beyond "stream of Event notifications" (see
// KNOCK-07 report, Choices ledger). This client expects each streamed event
// as its own line: {"jsonrpc":"2.0","method":"event","params":Event}.
struct JSONRPCNotification<Params: Decodable>: Decodable {
    var jsonrpc: String?
    var method: String
    var params: Params
}

// Minimal peek to route an incoming line before its full shape is known.
struct JSONRPCLinePeek: Decodable {
    var id: Int?
    var method: String?
}

// A params/result value with nothing to carry. Encodes as `{}` and decodes
// from anything (object, null, array) by ignoring its contents.
struct EmptyParams: Encodable, Sendable {}

struct EmptyResult: Decodable, Sendable {
    init() {}
    init(from decoder: Decoder) throws {}
}

// --- App and CLI methods (docs/protocol-mvp.md "Socket RPC") ---

struct CasesListParams: Encodable, Sendable {
    let status: CaseStatus?
}

struct CasesGetParams: Encodable, Sendable {
    let id: String
}

struct ArtifactPathParams: Encodable, Sendable {
    let caseId: String
    let revision: Int

    private enum CodingKeys: String, CodingKey {
        case caseId = "case_id", revision
    }
}

enum CaptureImageKind: String, Codable, Sendable {
    case raw, annotated
}

struct CaptureImageParams: Encodable, Sendable {
    let captureId: String
    let which: CaptureImageKind

    private enum CodingKeys: String, CodingKey {
        case captureId = "capture_id", which
    }
}

struct CaptureImageResult: Decodable, Sendable {
    let pngBase64: String

    private enum CodingKeys: String, CodingKey {
        case pngBase64 = "png_base64"
    }
}

struct ReplySubmitParams: Encodable, Sendable {
    let caseId: String
    let idempotencyKey: String
    let choice: String?
    /// "first" when the choice is an id of the ask's first option set (HAIL-108);
    /// `nil` means the newest set.
    var optionsSet: String? = nil
    let message: String?
    let comments: [Comment]
    let captures: [Capture]
    /// "decision" (default) or "more_detail" (HAIL-33).
    let intent: ReplyIntent
    /// The ticked option ids of a select "many" ask (HAIL-123); `nil` for a single choice.
    var choices: [String]? = nil
    /// The answers to the points of a multi-question request; `nil` for none.
    var answers: [PointAnswer]? = nil
    /// The answers by item id of a Decide reply (WAG-315); `nil` for none.
    var itemAnswers: [ItemAnswer]? = nil
    /// The format a `more_detail` reply asks for (HAIL-139); `nil` for none.
    var format: ReplyFormat? = nil
    /// The revision by the person this reply carries as their edit (HAIL-168); `nil` for none.
    var edit: ReplyEditRef? = nil
    /// A discuss reply (WAG-301): option ids the human leans to and rules out; `nil` for none.
    var leaning: [String]? = nil
    var ruledOut: [String]? = nil
    /// Files staged in the data folder's `incoming/` (WAG-345); `nil` for none.
    var attachments: [ReplyAttachmentInput]? = nil

    private enum CodingKeys: String, CodingKey {
        case caseId = "case_id"
        case idempotencyKey = "idempotency_key"
        case optionsSet = "options_set"
        case ruledOut = "ruled_out"
        case choice, choices, answers, message, comments, captures, intent, format, edit, leaning, attachments
        case itemAnswers = "item_answers"
    }
}

/// One entry of `attachments` in `reply.submit` and `reply.replace` (WAG-345). A new file names its copy in
/// `incoming/`; a file the queued reply already holds names its stored `path`.
struct ReplyAttachmentInput: Codable, Equatable, Sendable {
    let name: String
    var incomingPath: String? = nil
    var path: String? = nil
    var type: String? = nil

    private enum CodingKeys: String, CodingKey {
        case name, path, type
        case incomingPath = "incoming_path"
    }
}

/// `edit: { revision }` of `reply.submit` and `reply.replace` (HAIL-168).
struct ReplyEditRef: Codable, Equatable, Sendable {
    let revision: Int
}

// revision.add_by_human (HAIL-168): the person's edited markdown, stored as the next revision.
struct RevisionAddByHumanParams: Encodable, Sendable {
    let caseId: String
    let baseRevision: Int
    let markdown: String

    private enum CodingKeys: String, CodingKey {
        case caseId = "case_id", baseRevision = "base_revision", markdown
    }
}

struct ReplyHandOverParams: Encodable, Sendable {
    let replyId: String

    private enum CodingKeys: String, CodingKey {
        case replyId = "reply_id"
    }
}

struct ReplyRetryParams: Encodable, Sendable {
    let replyId: String

    private enum CodingKeys: String, CodingKey {
        case replyId = "reply_id"
    }
}

// reply.replace (HAIL-34): changes a queued reply's choice/message/comments/
// captures in place, under its existing id - "Change answer" while the reply
// is still queued (docs/protocol-mvp.md "reply.replace").
struct ReplyReplaceParams: Encodable, Sendable {
    let replyId: String
    let choice: String?
    var optionsSet: String? = nil
    let message: String?
    let comments: [Comment]
    let captures: [Capture]
    var choices: [String]? = nil
    var answers: [PointAnswer]? = nil
    var itemAnswers: [ItemAnswer]? = nil
    /// Omitted drops the edit from the reply (HAIL-168, Remove).
    var edit: ReplyEditRef? = nil
    /// Omitted keeps the files the reply holds; an empty list drops them (WAG-345).
    var attachments: [ReplyAttachmentInput]? = nil

    private enum CodingKeys: String, CodingKey {
        case replyId = "reply_id"
        case optionsSet = "options_set"
        case choice, choices, answers, message, comments, captures, edit, attachments
        case itemAnswers = "item_answers"
    }
}

// case.dismiss / case.restore (HAIL-32): both take just the case id.
struct CaseDismissParams: Encodable, Sendable {
    let caseId: String

    private enum CodingKeys: String, CodingKey {
        case caseId = "case_id"
    }
}

// case.change_mind (WAG-412): the case a rule decided is an open ask again.
struct CaseChangeMindParams: Encodable, Sendable {
    let caseId: String

    private enum CodingKeys: String, CodingKey {
        case caseId = "case_id"
    }
}

// cases.auto_decided (WAG-412): the cases a rule decided since an ISO time.
struct CasesAutoDecidedParams: Encodable, Sendable {
    let since: String?
}

struct CaseRestoreParams: Encodable, Sendable {
    let caseId: String

    private enum CodingKeys: String, CodingKey {
        case caseId = "case_id"
    }
}

// cases.resolved_stats / cases.purge_resolved (HAIL-52): the Data & privacy
// page's "Answered asks" row and its "Clear answered…" action.
// docs/protocol-mvp.md "cases.purge_resolved".
struct CasesResolvedStatsResult: Decodable, Sendable {
    let count: Int
    let bytes: Int
}

struct CasesPurgeResolvedResult: Decodable, Sendable {
    let purgedCases: Int
    let freedBytes: Int

    private enum CodingKeys: String, CodingKey {
        case purgedCases = "purged_cases"
        case freedBytes = "freed_bytes"
    }
}

// settings.get / settings.set (HAIL-100): the Artifacts preset the daemon
// persists. docs/protocol-mvp.md "Artifact preset".
enum ArtifactPreset: String, Codable, CaseIterable, Sendable, Identifiable {
    case quick
    case visual
    case rich

    var id: String { rawValue }
}

struct SettingsGetParams: Encodable, Sendable {
    let key: String
}

struct SettingsSetParams<Value: Encodable & Sendable>: Encodable, Sendable {
    let key: String
    let value: Value
}

struct SettingsResult<Value: Decodable & Sendable>: Decodable, Sendable {
    let key: String
    let value: Value
}

// Ask preferences (HAIL-101): what agents bring the operator. The daemon
// stores them and generates the text agents read (`askText`).
// docs/protocol-mvp.md "Ask preferences".
enum AskTopic: String, Codable, CaseIterable, Sendable, Identifiable {
    case marketing, design, operations, pricing, code, writing, data, personal, reviews
    case privateInfo = "private_info"

    var id: String { rawValue }
}

enum AskScope: String, Codable, CaseIterable, Sendable {
    case any
    case pick
}

/// The fixed categories of the "Ask less" rules (WAG-412), in the order the page lists them.
enum AskCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case naming
    case wording
    case formatting
    case tests

    var id: String { rawValue }

    var title: String {
        switch self {
        case .naming: "Naming"
        case .wording: "Wording"
        case .formatting: "Formatting"
        case .tests: "Test choices"
        }
    }

    var detail: String {
        switch self {
        case .naming: "Names of files, functions and variables."
        case .wording: "Small text choices, like a label or a message."
        case .formatting: "Spacing, order and style."
        case .tests: "Which tests to write or run for a small change."
        }
    }
}

/// "Let the agent decide small things" (WAG-412). The daemon holds it and keeps every rule off while the master is off.
struct AskLess: Codable, Equatable, Sendable {
    var enabled: Bool
    var rules: [String: Bool]

    static let off = AskLess(enabled: false, rules: [:])

    /// Two values are equal when the same categories are on, whether or not an off rule is written out.
    static func == (lhs: AskLess, rhs: AskLess) -> Bool {
        lhs.enabled == rhs.enabled && AskCategory.allCases.allSatisfy { lhs.isOn($0) == rhs.isOn($0) }
    }

    func isOn(_ category: AskCategory) -> Bool { enabled && (rules[category.rawValue] ?? false) }

    func setting(_ category: AskCategory, to on: Bool) -> AskLess {
        var next = self
        next.rules[category.rawValue] = on
        return next
    }

    /// Every category written out, so the daemon's strict shape is met.
    var wire: AskLess {
        AskLess(enabled: enabled, rules: Dictionary(uniqueKeysWithValues: AskCategory.allCases.map { ($0.rawValue, enabled && (rules[$0.rawValue] ?? false)) }))
    }
}

struct AskTopics: Codable, Equatable, Sendable {
    var scope: AskScope
    var picked: [AskTopic]
}

enum AskFrequency: String, Codable, CaseIterable, Sendable, Identifiable {
    case blocked
    case choice
    case chat

    var id: String { rawValue }
}

enum AskDetail: String, Codable, CaseIterable, Sendable, Identifiable {
    case brief
    case rich

    var id: String { rawValue }
}

/// HAIL-109 `askReach`: how much of what agents ask comes to Knock. Declared
/// in stop order, left to right on the slider. `off` (HAIL-193) brings nothing:
/// agents ask in the terminal.
enum AskReach: String, Codable, CaseIterable, Sendable, Identifiable {
    case off
    case visual
    case written
    case everything

    var id: String { rawValue }
}

/// HAIL-140 `askWords`: how agents write their asks. "asd" is ASD-STE100
/// Simplified Technical English (the default); "normal" is today's guidance.
enum AskWords: String, Codable, CaseIterable, Sendable, Identifiable {
    case asd
    case normal

    var id: String { rawValue }
}

/// WAG-384 `askLearn`: how the person likes to learn. It shapes an agent's answer to a "how it works"
/// request. "short" is the default; an older daemon has no such key, which reads as "short".
enum AskLearn: String, Codable, CaseIterable, Sendable, Identifiable {
    case short
    case diagram
    case steps
    case `try`

    var id: String { rawValue }
}

/// WAG-385 `askAfterDecide`: what the agent does once the person has decided. "record_tasks" is the
/// default; an older daemon has no such key, which reads as "record_tasks".
enum AskAfterDecide: String, Codable, CaseIterable, Sendable, Identifiable {
    case nothing = "none"
    case record
    case recordTasks = "record_tasks"

    var id: String { rawValue }
}

/// WAG-265 `catchQuestions`: whether the Claude Code plugin's Stop hook sends a question left in
/// the terminal back to Waggle. On by default.
enum CatchQuestions: String, Codable, Sendable {
    case on
    case off
}

// session.nudge (HAIL-76): `{ sent: true }` or `{ sent: false, reason }`.
struct NudgeParams: Encodable, Sendable {
    let caseId: String
    private enum CodingKeys: String, CodingKey { case caseId = "case_id" }
}

enum NudgeFailureReason: String, Codable, Sendable {
    case sessionClosed = "session_closed"
    case notSupported = "not_supported"
    case alreadyPickedUp = "already_picked_up"
    case rateLimited = "rate_limited"
    case postFailed = "post_failed"
}

struct NudgeResult: Decodable, Equatable, Sendable {
    let sent: Bool
    let reason: NudgeFailureReason?

    init(sent: Bool, reason: NudgeFailureReason? = nil) {
        self.sent = sent
        self.reason = reason
    }
}

// session.send_prompt (HAIL-169): `{ sent: true }` or `{ sent: false, reason }`.
struct SendPromptParams: Encodable, Sendable {
    let sessionId: String
    let text: String
    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case text
    }
}

enum SendPromptFailureReason: String, Codable, Sendable {
    case sessionClosed = "session_closed"
    case notSupported = "not_supported"
    case postFailed = "post_failed"
}

struct SendPromptResult: Decodable, Equatable, Sendable {
    let sent: Bool
    let reason: SendPromptFailureReason?

    init(sent: Bool, reason: SendPromptFailureReason? = nil) {
        self.sent = sent
        self.reason = reason
    }
}

// Chat connectors (HAIL-144): Telegram first. Off until the operator connects it in Settings.
// docs/protocol-mvp.md "Chat connectors". The bot token goes to the daemon once and never comes back.
enum ConnectorState: String, Codable, Sendable {
    case off
    case tokenChecked = "token_checked"
    case waitingForStart = "waiting_for_start"
    case connected
}

struct TelegramStatus: Codable, Equatable, Sendable {
    let state: ConnectorState
    let botName: String?
    let botUsername: String?
    /// The chat's name as Telegram gave it on /start, once connected.
    let chatLabel: String?
    /// The one-time code to send while `state` is `.waitingForStart`.
    let code: String?
    /// The last problem, in plain words.
    let error: String?

    static let off = TelegramStatus(state: .off, botName: nil, botUsername: nil, chatLabel: nil, code: nil, error: nil)

    private enum CodingKeys: String, CodingKey {
        case state
        case botName = "bot_name"
        case botUsername = "bot_username"
        case chatLabel = "chat_label"
        case code, error
    }
}

/// Slack (HAIL-145). Same states as Telegram: `.tokenChecked` = both tokens are good,
/// `.waitingForStart` = DM the bot the one-time `code`.
struct SlackStatus: Codable, Equatable, Sendable {
    let state: ConnectorState
    let workspace: String?
    let botName: String?
    /// The linked person's name in Slack, once connected.
    let userLabel: String?
    let code: String?
    /// The Slack app manifest (JSON) the operator copies to make the app.
    let manifest: String
    let error: String?
    /// For the guided links (HAIL-148). Nil from a daemon that does not know them yet.
    let appId: String?
    let teamId: String?
    let botUserId: String?

    init(
        state: ConnectorState, workspace: String?, botName: String?, userLabel: String?, code: String?,
        manifest: String, error: String?, appId: String? = nil, teamId: String? = nil, botUserId: String? = nil
    ) {
        self.state = state
        self.workspace = workspace
        self.botName = botName
        self.userLabel = userLabel
        self.code = code
        self.manifest = manifest
        self.error = error
        self.appId = appId
        self.teamId = teamId
        self.botUserId = botUserId
    }

    static let off = SlackStatus(state: .off, workspace: nil, botName: nil, userLabel: nil, code: nil, manifest: "", error: nil)

    private enum CodingKeys: String, CodingKey {
        case state, workspace
        case botName = "bot_name"
        case userLabel = "user_label"
        case code, manifest, error
        case appId = "app_id"
        case teamId = "team_id"
        case botUserId = "bot_user_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(ConnectorState.self, forKey: .state)
        workspace = try c.decodeIfPresent(String.self, forKey: .workspace)
        botName = try c.decodeIfPresent(String.self, forKey: .botName)
        userLabel = try c.decodeIfPresent(String.self, forKey: .userLabel)
        code = try c.decodeIfPresent(String.self, forKey: .code)
        manifest = try c.decode(String.self, forKey: .manifest)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        appId = try c.decodeIfPresent(String.self, forKey: .appId)
        teamId = try c.decodeIfPresent(String.self, forKey: .teamId)
        botUserId = try c.decodeIfPresent(String.self, forKey: .botUserId)
    }
}

struct ConnectorsStatusResult: Decodable, Sendable {
    let telegram: TelegramStatus
    /// `.off` when the daemon predates Slack.
    let slack: SlackStatus

    private enum CodingKeys: String, CodingKey { case telegram, slack }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        telegram = try c.decode(TelegramStatus.self, forKey: .telegram)
        slack = try c.decodeIfPresent(SlackStatus.self, forKey: .slack) ?? .off
    }
}

struct SlackCheckTokensParams: Encodable, Sendable {
    let appToken: String
    let botToken: String

    private enum CodingKeys: String, CodingKey {
        case appToken = "app_token"
        case botToken = "bot_token"
    }
}

struct SlackLookUpAppParams: Encodable, Sendable {
    let botToken: String

    private enum CodingKeys: String, CodingKey { case botToken = "bot_token" }
}

struct TelegramCheckTokenParams: Encodable, Sendable {
    let token: String
}

struct ConnectorOkResult: Decodable, Sendable {
    let ok: Bool
}

// design_kit.get / design_kit.set / design_kit.undo (HAIL-166): the default design kit.
// docs/protocol-mvp.md "Default design kit and knock_settings".
struct DesignKit: Codable, Equatable, Sendable {
    var designSystem: String
    var penFile: String
    var tone: String
    var enabled: Bool
    var updatedAt: String?
    var updatedBy: String?

    static let empty = DesignKit(designSystem: "", penFile: "", tone: "", enabled: false, updatedAt: nil, updatedBy: nil)

    private enum CodingKeys: String, CodingKey {
        case designSystem = "design_system"
        case penFile = "pen_file"
        case tone
        case enabled
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
    }
}

struct DesignKitResult: Decodable, Equatable, Sendable {
    let kit: DesignKit
    let canUndo: Bool

    private enum CodingKeys: String, CodingKey {
        case kit
        case canUndo = "can_undo"
    }
}

/// A change to the kit: only the fields that are set are sent.
struct DesignKitChange: Encodable, Equatable, Sendable {
    var designSystem: String?
    var penFile: String?
    var tone: String?
    var enabled: Bool?

    var isEmpty: Bool { designSystem == nil && penFile == nil && tone == nil && enabled == nil }

    private enum CodingKeys: String, CodingKey {
        case designSystem = "design_system"
        case penFile = "pen_file"
        case tone
        case enabled
    }
}

// Sharing a case (WAG-387). Off until the operator turns Sharing on in Settings.
// docs/protocol-mvp.md "Sharing a case". The owner key never comes over the socket.
enum SharingMode: String, Codable, Sendable {
    case link
    case emails
}

struct SharedCommentBox: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let w: Double
    let h: Double
    let vw: Double
    let near: String
}

/// One comment from the team on a shared case. Plain text; never a reply.
struct SharedComment: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let revision: Int?
    let authorName: String
    /// `owner`, `member`, `guest` or `agent` (WAG-392, WAG-394). An old `email` value reads as a member.
    let authorKind: String
    /// Set for the owner and members, nil for guests.
    let authorEmail: String?
    let body: String
    let quote: String?
    let prefix: String?
    let suffix: String?
    let box: SharedCommentBox?
    let createdAt: String
    /// The root comment this one answers (WAG-394). Nil for a root.
    let parentId: String?
    /// Set on a root comment the owner resolved. Nil while it is open.
    let resolvedAt: String?
    let resolvedBy: String?
    /// True until the owner opens the case (`sharing.mark_seen`).
    let unread: Bool

    init(
        id: String, revision: Int?, authorName: String, authorKind: String, authorEmail: String? = nil, body: String,
        quote: String?, prefix: String?, suffix: String?, box: SharedCommentBox?, createdAt: String,
        parentId: String? = nil, resolvedAt: String? = nil, resolvedBy: String? = nil, unread: Bool = false
    ) {
        self.parentId = parentId
        self.resolvedAt = resolvedAt
        self.resolvedBy = resolvedBy
        self.unread = unread
        self.id = id
        self.revision = revision
        self.authorName = authorName
        self.authorKind = authorKind
        self.authorEmail = authorEmail
        self.body = body
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
        self.box = box
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision)
        authorName = try c.decode(String.self, forKey: .authorName)
        authorKind = try c.decode(String.self, forKey: .authorKind)
        authorEmail = try c.decodeIfPresent(String.self, forKey: .authorEmail)
        body = try c.decode(String.self, forKey: .body)
        quote = try c.decodeIfPresent(String.self, forKey: .quote)
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix)
        suffix = try c.decodeIfPresent(String.self, forKey: .suffix)
        box = try c.decodeIfPresent(SharedCommentBox.self, forKey: .box)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
        resolvedAt = try c.decodeIfPresent(String.self, forKey: .resolvedAt)
        resolvedBy = try c.decodeIfPresent(String.self, forKey: .resolvedBy)
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, revision, body, quote, prefix, suffix, box, unread
        case parentId = "parent_id"
        case resolvedAt = "resolved_at"
        case resolvedBy = "resolved_by"
        case authorEmail = "author_email"
        case authorName = "author_name"
        case authorKind = "author_kind"
        case createdAt = "created_at"
    }
}

struct CaseShare: Codable, Equatable, Sendable {
    let url: String
    let mode: SharingMode
    let emails: [String]
    /// False when this Mac no longer has the key for the link, so it cannot be stopped from here (WAG-391).
    let stoppable: Bool

    init(url: String, mode: SharingMode, emails: [String], stoppable: Bool = true) {
        self.url = url
        self.mode = mode
        self.emails = emails
        self.stoppable = stoppable
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        mode = try c.decode(SharingMode.self, forKey: .mode)
        emails = try c.decode([String].self, forKey: .emails)
        stoppable = try c.decodeIfPresent(Bool.self, forKey: .stoppable) ?? true
    }

    private enum CodingKeys: String, CodingKey { case url, mode, emails, stoppable }
}

/// A round the relay can never take (too big, too many files), with a plain reason.
struct SkippedRound: Codable, Equatable, Sendable {
    let revision: Int
    let reason: String
}

/// The sign-in a pending connect shows: a code and the page to open (WAG-392).
struct AccountConnect: Codable, Equatable, Sendable {
    let userCode: String
    let verifyUrl: String
    let expiresAt: Double

    private enum CodingKeys: String, CodingKey {
        case userCode = "user_code"
        case verifyUrl = "verify_url"
        case expiresAt = "expires_at"
    }
}

/// The Waggle account on this Mac (WAG-392). Local use needs none; sharing does.
struct AccountState: Codable, Equatable, Sendable {
    let signedIn: Bool
    let email: String?
    let connect: AccountConnect?
    let error: String?

    init(signedIn: Bool, email: String? = nil, connect: AccountConnect? = nil, error: String? = nil) {
        self.signedIn = signedIn
        self.email = email
        self.connect = connect
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        signedIn = try c.decode(Bool.self, forKey: .signedIn)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        connect = try c.decodeIfPresent(AccountConnect.self, forKey: .connect)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }

    static let signedOut = AccountState(signedIn: false)

    private enum CodingKeys: String, CodingKey {
        case signedIn = "signed_in"
        case email, connect, error
    }
}

/// One link in "Your shared links": every case this account shared, from any Mac.
struct AccountShare: Codable, Equatable, Identifiable, Sendable {
    let relayId: String
    let title: String
    let url: String
    let mode: SharingMode
    let createdAt: Double
    let commentCount: Int
    let deviceLabel: String
    let localCaseId: String?

    var id: String { relayId }

    private enum CodingKeys: String, CodingKey {
        case relayId = "relay_id"
        case title, url, mode
        case createdAt = "created_at"
        case commentCount = "comment_count"
        case deviceLabel = "device_label"
        case localCaseId = "local_case_id"
    }
}

struct AccountSharesResult: Codable, Equatable, Sendable {
    let shares: [AccountShare]
    let error: String?
}

struct AccountStopShareParams: Encodable, Sendable {
    let relayId: String
    private enum CodingKeys: String, CodingKey { case relayId = "relay_id" }
}

struct SharingUpdateParams: Encodable, Sendable {
    let caseId: String
    let mode: SharingMode
    let emails: [String]?

    private enum CodingKeys: String, CodingKey {
        case caseId = "case_id"
        case mode, emails
    }
}

struct SharingOpenPageResult: Codable, Equatable, Sendable {
    let url: String
}

/// How the invite mails of the last share or audience change went (WAG-392).
struct InviteCounts: Codable, Equatable, Sendable {
    let sent: Int
    let failed: Int
    let limited: Int

    static let none = InviteCounts(sent: 0, failed: 0, limited: 0)
}

/// Team comments that came after the last decide answer (WAG-401). `new` counts those the agent was not given yet.
struct LateComments: Codable, Equatable, Sendable {
    let count: Int
    let new: Int

    static let none = LateComments(count: 0, new: 0)
}

struct SharingState: Codable, Equatable, Sendable {
    /// False while the Sharing feature is hidden (the daemon's SHARING_AVAILABLE). An older daemon sends none: true.
    let available: Bool
    let enabled: Bool
    let sharedCount: Int
    let share: CaseShare?
    let comments: [SharedComment]
    /// The last problem with the relay for this case, in one plain line.
    let error: String?
    /// Rounds that were left out, each with the reason (WAG-391).
    let skipped: [SkippedRound]
    /// The invite mails of the last share or change. An older daemon sends none: that reads as all zero.
    let invites: InviteCounts
    /// The account on this Mac (WAG-392). An older daemon sends none: that reads as signed in, so nothing blocks.
    let account: AccountState
    /// The owner closed comments on this case (WAG-394).
    let commentsClosed: Bool
    /// The case was shared before and is not now (WAG-394): a new share makes a new link.
    let sharedBefore: Bool
    /// The late team comments of a decided case (WAG-401). An older daemon sends none: that reads as zero.
    let lateComments: LateComments

    init(
        enabled: Bool, sharedCount: Int, share: CaseShare?, comments: [SharedComment], error: String?,
        skipped: [SkippedRound] = [], invites: InviteCounts = .none, account: AccountState = AccountState(signedIn: true),
        commentsClosed: Bool = false, sharedBefore: Bool = false, lateComments: LateComments = .none,
        available: Bool = true
    ) {
        self.available = available
        self.lateComments = lateComments
        self.commentsClosed = commentsClosed
        self.sharedBefore = sharedBefore
        self.invites = invites
        self.account = account
        self.enabled = enabled
        self.sharedCount = sharedCount
        self.share = share
        self.comments = comments
        self.error = error
        self.skipped = skipped
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = try c.decodeIfPresent(Bool.self, forKey: .available) ?? true
        enabled = try c.decode(Bool.self, forKey: .enabled)
        sharedCount = try c.decode(Int.self, forKey: .sharedCount)
        share = try c.decodeIfPresent(CaseShare.self, forKey: .share)
        comments = try c.decode([SharedComment].self, forKey: .comments)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        skipped = try c.decodeIfPresent([SkippedRound].self, forKey: .skipped) ?? []
        invites = try c.decodeIfPresent(InviteCounts.self, forKey: .invites) ?? .none
        account = try c.decodeIfPresent(AccountState.self, forKey: .account) ?? AccountState(signedIn: true)
        commentsClosed = try c.decodeIfPresent(Bool.self, forKey: .commentsClosed) ?? false
        sharedBefore = try c.decodeIfPresent(Bool.self, forKey: .sharedBefore) ?? false
        lateComments = try c.decodeIfPresent(LateComments.self, forKey: .lateComments) ?? .none
    }

    static let off = SharingState(enabled: false, sharedCount: 0, share: nil, comments: [], error: nil)

    private enum CodingKeys: String, CodingKey {
        case available, enabled, share, comments, error, skipped, invites, account
        case sharedCount = "shared_count"
        case commentsClosed = "comments_closed"
        case sharedBefore = "shared_before"
        case lateComments = "late_comments"
    }
}

struct SharingGetParams: Encodable, Sendable {
    let caseId: String?

    private enum CodingKeys: String, CodingKey { case caseId = "case_id" }
}

struct SharingSetEnabledParams: Encodable, Sendable {
    let enabled: Bool
}

struct SharingStartParams: Encodable, Sendable {
    let caseId: String
    let mode: SharingMode
    let emails: [String]

    private enum CodingKeys: String, CodingKey {
        case caseId = "case_id"
        case mode, emails
    }
}

struct SharingCaseParams: Encodable, Sendable {
    let caseId: String

    private enum CodingKeys: String, CodingKey { case caseId = "case_id" }
}

// MARK: The comment loop (WAG-394)

struct SharingReplyParams: Encodable, Sendable {
    let caseId: String
    let parentId: String
    let body: String

    private enum CodingKeys: String, CodingKey {
        case caseId = "case_id"
        case parentId = "parent_id"
        case body
    }
}

/// WAG-397: a comment from the owner on the page, with no parent.
struct SharingCommentParams: Encodable, Sendable {
    let caseId: String
    let body: String

    private enum CodingKeys: String, CodingKey {
        case caseId = "case_id"
        case body
    }
}

struct SharingResolveParams: Encodable, Sendable {
    let caseId: String
    let commentId: String
    let resolved: Bool

    private enum CodingKeys: String, CodingKey {
        case caseId = "case_id"
        case commentId = "comment_id"
        case resolved
    }
}

struct SharingCloseCommentsParams: Encodable, Sendable {
    let caseId: String
    let closed: Bool

    private enum CodingKeys: String, CodingKey {
        case caseId = "case_id"
        case closed
    }
}

struct SharingReopenParams: Encodable, Sendable {
    let caseId: String
    let reopened: Bool

    private enum CodingKeys: String, CodingKey {
        case caseId = "case_id"
        case reopened
    }
}

struct UnreadCase: Codable, Equatable, Sendable {
    let caseId: String
    let count: Int

    private enum CodingKeys: String, CodingKey {
        case caseId = "case_id"
        case count
    }
}

struct SharingUnreadResult: Codable, Equatable, Sendable {
    let cases: [UnreadCase]
}

/// One new team comment the daemon has not announced yet.
struct TeamCommentNotice: Codable, Equatable, Sendable {
    let caseId: String
    let caseTitle: String
    let commentId: String
    let authorName: String
    let body: String

    private enum CodingKeys: String, CodingKey {
        case caseId = "case_id"
        case caseTitle = "case_title"
        case commentId = "comment_id"
        case authorName = "author_name"
        case body
    }
}

struct SharingNotificationsResult: Codable, Equatable, Sendable {
    let items: [TeamCommentNotice]
}
