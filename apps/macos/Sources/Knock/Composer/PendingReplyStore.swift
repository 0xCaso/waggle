import Foundation

/// A reply the app has decided to send but has not yet confirmed the daemon
/// received (docs/protocol-mvp.md `reply.submit` params, plus the
/// idempotency key AC 4/5 need to persist across a retry or a reconnect).
/// Snake-case keys, matching `ReplySubmitParams` and every other wire-shaped
/// type in `Protocol/` - this is a locally-invented file format (the
/// protocol doc does not define it), but there is no reason to diverge.
struct PendingReply: Codable, Equatable, Sendable {
    let caseId: String
    let idempotencyKey: String
    let choice: String?
    let message: String?
    var comments: [Comment]
    let captures: [Capture]
    /// "decision" (default) or "more_detail" (HAIL-33). Defaults so a pending
    /// file saved before this field existed still decodes.
    var intent: ReplyIntent = .decision
    /// The format a `more_detail` reply asks for (HAIL-139); `nil` for none.
    /// Defaults so a pending file saved before this field existed still decodes.
    var format: ReplyFormat? = nil
    /// "first" when the choice came from the ask's first option set (HAIL-108).
    /// Defaults so a pending file saved before this field existed still decodes.
    var optionsSet: String? = nil
    /// The ticked option ids of a select "many" ask (HAIL-123); `nil` for a single choice.
    var choices: [String]? = nil
    /// The revision by the person this reply carries as their edit (HAIL-168); `nil` for none.
    var editRevision: Int? = nil
    /// The answers to the points of a multi-question request (WAG-257); `nil` for none.
    var answers: [PointAnswer]? = nil
    /// The answers by item id of a Decide reply (WAG-315); `nil` for none. Saved with the reply so a retry sends them again.
    var itemAnswers: [ItemAnswer]? = nil
    /// A discuss reply (WAG-301): option ids the human leans to and rules out; `nil` for none.
    var leaning: [String]? = nil
    var ruledOut: [String]? = nil
    /// The files staged for this reply (WAG-345); `nil` for none. Saved so a retry sends them again.
    var attachments: [ReplyAttachmentInput]? = nil

    private enum CodingKeys: String, CodingKey {
        case attachments
        case ruledOut = "ruled_out"
        case leaning
        case caseId = "case_id"
        case idempotencyKey = "idempotency_key"
        case optionsSet = "options_set"
        case editRevision = "edit_revision"
        case choice, choices, answers, message, comments, captures, intent, format
        case itemAnswers = "item_answers"
    }

    init(
        caseId: String, idempotencyKey: String, choice: String?, message: String?,
        comments: [Comment], captures: [Capture], intent: ReplyIntent = .decision,
        format: ReplyFormat? = nil,
        optionsSet: String? = nil, choices: [String]? = nil, editRevision: Int? = nil,
        answers: [PointAnswer]? = nil, leaning: [String]? = nil, ruledOut: [String]? = nil,
        itemAnswers: [ItemAnswer]? = nil, attachments: [ReplyAttachmentInput]? = nil
    ) {
        self.attachments = attachments
        self.itemAnswers = itemAnswers
        self.leaning = leaning
        self.ruledOut = ruledOut
        self.answers = answers
        self.editRevision = editRevision
        self.choices = choices
        self.caseId = caseId
        self.idempotencyKey = idempotencyKey
        self.choice = choice
        self.message = message
        self.comments = comments
        self.captures = captures
        self.intent = intent
        self.format = format
        self.optionsSet = optionsSet
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        caseId = try c.decode(String.self, forKey: .caseId)
        idempotencyKey = try c.decode(String.self, forKey: .idempotencyKey)
        choice = try c.decodeIfPresent(String.self, forKey: .choice)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        comments = try c.decode([Comment].self, forKey: .comments)
        captures = try c.decode([Capture].self, forKey: .captures)
        intent = try c.decodeIfPresent(ReplyIntent.self, forKey: .intent) ?? .decision
        format = try c.decodeIfPresent(ReplyFormat.self, forKey: .format)
        optionsSet = try c.decodeIfPresent(String.self, forKey: .optionsSet)
        choices = try c.decodeIfPresent([String].self, forKey: .choices)
        editRevision = try c.decodeIfPresent(Int.self, forKey: .editRevision)
        answers = try c.decodeIfPresent([PointAnswer].self, forKey: .answers)
        itemAnswers = try c.decodeIfPresent([ItemAnswer].self, forKey: .itemAnswers)
        leaning = try c.decodeIfPresent([String].self, forKey: .leaning)
        ruledOut = try c.decodeIfPresent([String].self, forKey: .ruledOut)
        attachments = try c.decodeIfPresent([ReplyAttachmentInput].self, forKey: .attachments)
    }
}

extension PendingReply {
    /// A copy whose comment rects are all inside 0..1 (WAG-349).
    func withClampedRects() -> PendingReply {
        var copy = self
        copy.comments = comments.map { $0.withRect($0.rect.clamped()) }
        return copy
    }
}

/// Persists replies the app could not yet confirm delivered, in the app
/// support dir - never the daemon's `knock.db` (AGENTS.md: "The daemon is the
/// only writer of knock.db"; docs/protocol-mvp.md: "the app keeps the unsent
/// reply locally"). One file per case: a case has at most one outstanding
/// send in flight at a time, keyed so a later send for the same case
/// overwrites rather than accumulates.
struct PendingReplyStore: Sendable {
    let directoryURL: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home: String
        if let override = environment["KNOCK_HOME"], !override.isEmpty {
            home = override
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Knock", isDirectory: true).path
        }
        directoryURL = URL(fileURLWithPath: home).appendingPathComponent("pending-replies", isDirectory: true)
    }

    private func fileURL(caseId: String) -> URL {
        directoryURL.appendingPathComponent("\(caseId).json")
    }

    func save(_ reply: PendingReply) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(reply)
        try data.write(to: fileURL(caseId: reply.caseId), options: .atomic)
    }

    func load(caseId: String) -> PendingReply? {
        guard let data = try? Data(contentsOf: fileURL(caseId: caseId)) else { return nil }
        return try? JSONDecoder().decode(PendingReply.self, from: data)
    }

    func remove(caseId: String) {
        try? FileManager.default.removeItem(at: fileURL(caseId: caseId))
    }

    /// Every reply still waiting to be confirmed delivered, across every
    /// case - what a reconnect resubmits (docs/protocol-mvp.md: "On
    /// reconnect it re-submits with the same key"). A file that fails to
    /// decode (a partial write, a format this build no longer understands)
    /// is moved to `pending-replies/bad/` rather than left in place to be
    /// retried and fail again on every future reconnect (AC).
    func loadAll() -> [PendingReply] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            if let reply = try? JSONDecoder().decode(PendingReply.self, from: data) {
                return reply
            }
            moveToBad(url)
            return nil
        }
    }

    private func moveToBad(_ url: URL) {
        let badDirectory = directoryURL.appendingPathComponent("bad", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: badDirectory, withIntermediateDirectories: true)) != nil else { return }
        let destination = badDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: url, to: destination)
    }
}
