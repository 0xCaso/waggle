import Foundation

// The three blocks model on the wire (WAG-310 spec, WAG-312 daemon schemas): an Ask carries items, a Reply
// carries item answers and an outcome, a Round is one turn of the agent on the same case. Everything here
// is additive and forgiving: a value this app does not know never fails the case list decode. The closed
// enums `Case.Kind`, `Case.Select` and `ReplyIntent` are unchanged.

/// How the human answers one item: pick one, pick several, or write a reply.
enum ItemSelect: String, Codable, Equatable, Sendable {
    case one
    case many
    case reply
}

/// Items with the same group id share a heading, the "how it works now" lines and the artifact variants
/// (it replaces the old `Question` wrapper).
struct ItemGroup: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let now: [String]?
    let variants: [QuestionVariant]?
    let variantLabel: String?

    init(id: String, title: String, now: [String]? = nil, variants: [QuestionVariant]? = nil, variantLabel: String? = nil) {
        self.id = id
        self.title = title
        self.now = now
        self.variants = variants
        self.variantLabel = variantLabel
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, now, variants
        case variantLabel = "variant_label"
    }
}

/// One decision inside an Ask (daemon `Item`).
struct Item: Codable, Equatable, Sendable, Identifiable {
    let id: String
    /// What this item asks. `nil` on a single item: the ask's need stands in.
    let question: String?
    let select: ItemSelect
    /// Only with `.many`.
    let max: Int?
    /// Empty with `.reply`.
    let options: [Option]
    /// One option id; several with `.many`; the suggested reply text with `.reply`. Empty when none.
    let recommendation: [String]
    let recommendationWhy: String?
    let group: ItemGroup?

    init(
        id: String, question: String? = nil, select: ItemSelect = .one, max: Int? = nil, options: [Option] = [],
        recommendation: [String] = [], recommendationWhy: String? = nil, group: ItemGroup? = nil
    ) {
        self.id = id
        self.question = question
        self.select = select
        self.max = max
        self.options = options
        self.recommendation = recommendation
        self.recommendationWhy = recommendationWhy
        self.group = group
    }

    private enum CodingKeys: String, CodingKey {
        case id, question, select, max, options, recommendation, group
        case recommendationWhy = "recommendation_why"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        question = try c.decodeIfPresent(String.self, forKey: .question)
        options = try c.decodeIfPresent([Option].self, forKey: .options) ?? []
        // A select this app does not know reads as the daemon's own default: one with options, else a reply.
        select = (try? c.decodeIfPresent(ItemSelect.self, forKey: .select)) ?? (options.isEmpty ? .reply : .one)
        max = try c.decodeIfPresent(Int.self, forKey: .max)
        if let one = try? c.decodeIfPresent(String.self, forKey: .recommendation) {
            recommendation = [one]
        } else {
            recommendation = (try? c.decodeIfPresent([String].self, forKey: .recommendation)) ?? []
        }
        recommendationWhy = try c.decodeIfPresent(String.self, forKey: .recommendationWhy)
        group = (try? c.decodeIfPresent(ItemGroup.self, forKey: .group)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(question, forKey: .question)
        try c.encode(select, forKey: .select)
        try c.encodeIfPresent(max, forKey: .max)
        try c.encode(options, forKey: .options)
        if select == .many, !recommendation.isEmpty {
            try c.encode(recommendation, forKey: .recommendation)
        } else if let first = recommendation.first {
            try c.encode(first, forKey: .recommendation)
        }
        try c.encodeIfPresent(recommendationWhy, forKey: .recommendationWhy)
        try c.encodeIfPresent(group, forKey: .group)
    }
}

/// One answered item of a Decide reply (`reply.submit` `item_answers`). Exactly one of `choice` (an option
/// id), `choices` (option ids, with a "many" item) or `text` (a "reply" item) is set.
struct ItemAnswer: Codable, Equatable, Sendable {
    let itemId: String
    var choice: String?
    var choices: [String]?
    var text: String?
    var note: String?
    /// WAG-328: true when the person chose `choice` themselves (a click, a key, or a button that names it).
    /// The daemon stores a choice marked `false` as Keep talking. `nil` is an older app: today's rules.
    var confirmed: Bool?

    init(
        itemId: String, choice: String? = nil, choices: [String]? = nil, text: String? = nil, note: String? = nil,
        confirmed: Bool? = nil
    ) {
        self.confirmed = confirmed
        self.itemId = itemId
        self.choice = choice
        self.choices = choices
        self.text = text
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case choice, choices, text, note, confirmed
    }
}

/// What a reply is in the three blocks model: the human decided, or wants to keep talking. The daemon sets
/// it on read; this app never sends it.
enum ReplyOutcome: String, Codable, Equatable, Sendable {
    case decide
    case talk
}

/// The human's Decide for one Round.
struct RoundAnswer: Codable, Equatable, Sendable {
    let choice: String?
    let choices: [String]?
    let itemAnswers: [ItemAnswer]?
    let message: String?
    let createdAt: String

    private enum CodingKeys: String, CodingKey {
        case choice, choices, message
        case itemAnswers = "item_answers"
        case createdAt = "created_at"
    }
}

/// One Round of a case: an option set that carries items (`CaseDetail.rounds`). It generalises `PlanRound`.
struct Round: Codable, Equatable, Sendable, Identifiable {
    var id: Int { seq }
    let seq: Int
    let stage: PlanStage?
    /// The agent message that opened the round (the ask's need for round 0).
    let question: String
    let items: [Item]
    let createdAt: String
    let revision: Int?
    let ownArtifact: Bool
    let artifactKind: ArtifactKind?
    /// `nil` while the round is open.
    let answer: RoundAnswer?
    /// How many Keep talking replies the round got.
    let talkCount: Int
    /// What the agent's text cites (WAG-356). Empty on an older daemon.
    let sources: [Source]

    private enum CodingKeys: String, CodingKey {
        case seq, stage, question, items, revision, answer, sources
        case createdAt = "created_at"
        case ownArtifact = "own_artifact"
        case artifactKind = "artifact_kind"
        case talkCount = "talk_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        stage = (try? c.decodeIfPresent(PlanStage.self, forKey: .stage)) ?? nil
        question = try c.decodeIfPresent(String.self, forKey: .question) ?? ""
        items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        createdAt = try c.decode(String.self, forKey: .createdAt)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision)
        ownArtifact = try c.decodeIfPresent(Bool.self, forKey: .ownArtifact) ?? false
        artifactKind = (try? c.decodeIfPresent(ArtifactKind.self, forKey: .artifactKind)) ?? nil
        answer = (try? c.decodeIfPresent(RoundAnswer.self, forKey: .answer)) ?? nil
        talkCount = try c.decodeIfPresent(Int.self, forKey: .talkCount) ?? 0
        sources = (try? c.decodeIfPresent(LossyList<Source>.self, forKey: .sources))??.elements ?? []
    }
}
