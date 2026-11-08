import Foundation

// Sources on a request (WAG-356, daemon side WAG-354). A round carries `sources`; the agent's text cites them
// with markers `[[s:ID]]` or `[[s:ID,ID2]]` after a sentence. Everything here is forgiving: a field this app
// does not know is ignored, a source that does not decode is dropped, a kind it does not know uses the file icon.

/// The kind of a source. `raw` keeps what the wire said, so an unknown kind still has a name.
enum SourceKind: String, CaseIterable, Sendable {
    case file, document, image, search, history, test, database, api, tool, design, web, agent
    case youSaid = "you_said"
    case decision, rule, none

    /// The kind for a wire value; `nil` for a kind this app does not know.
    init?(wire: String?) {
        guard let wire else { return nil }
        self.init(rawValue: wire)
    }

    /// The SF Symbol closest to the design's Lucide icon (file-code, file-text, image, search, git-commit,
    /// flask-conical, database, globe, plug, pen-tool, link, bot, user, circle-check, scroll, circle-dashed).
    var symbol: String {
        switch self {
        case .file: "chevron.left.forwardslash.chevron.right"
        case .document: "doc.text"
        case .image: "photo"
        case .search: "magnifyingglass"
        case .history: "arrow.triangle.branch"
        case .test: "testtube.2"
        case .database: "cylinder"
        case .api: "globe"
        case .tool: "powerplug"
        case .design: "pencil.tip"
        case .web: "link"
        case .agent: "cpu"
        case .youSaid: "person"
        case .decision: "checkmark.circle"
        case .rule: "scroll"
        case .none: "circle.dashed"
        }
    }

    /// The kind in plain words, for the card head and the list.
    var title: String {
        switch self {
        case .file: "File or code"
        case .document: "Document"
        case .image: "Image or screen"
        case .search: "Search"
        case .history: "Version history"
        case .test: "Test or build"
        case .database: "Database query"
        case .api: "API call"
        case .tool: "Connected tool"
        case .design: "Design file"
        case .web: "Web page"
        case .agent: "Helper agent"
        case .youSaid: "You said"
        case .decision: "Earlier decision"
        case .rule: "Project rule"
        case .none: "No source"
        }
    }
}

enum SourceState: String, Sendable {
    case seen, stated, assumption
}

/// Where a source points. Text only: nothing here opens a file or a page.
struct SourceRef: Codable, Equatable, Sendable {
    var path: String?
    var line: Int?
    var command: String?
    var url: String?
    var tool: String?
    var caseId: String?

    private enum CodingKeys: String, CodingKey {
        case path, line, command, url, tool
        case caseId = "case_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try? c.decodeIfPresent(String.self, forKey: .path)
        line = try? c.decodeIfPresent(Int.self, forKey: .line)
        command = try? c.decodeIfPresent(String.self, forKey: .command)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        tool = try? c.decodeIfPresent(String.self, forKey: .tool)
        caseId = try? c.decodeIfPresent(String.self, forKey: .caseId)
    }
}

/// One cited source of a round.
struct Source: Codable, Equatable, Sendable, Identifiable {
    let id: String
    /// What the wire said. `kind` reads it.
    let rawKind: String?
    let label: String
    let note: String?
    let excerpt: String?
    let ref: SourceRef?
    let state: SourceState
    let seenAt: String?

    /// `nil` for a kind this app does not know: it shows with the file icon.
    var kind: SourceKind? { SourceKind(wire: rawKind) }
    /// The kind a pill and a card draw.
    var drawnKind: SourceKind { kind ?? .file }

    init(
        id: String, kind: String? = nil, label: String = "", note: String? = nil, excerpt: String? = nil,
        ref: SourceRef? = nil, state: SourceState = .stated, seenAt: String? = nil
    ) {
        self.id = id
        self.rawKind = kind
        self.label = label
        self.note = note
        self.excerpt = excerpt
        self.ref = ref
        self.state = state
        self.seenAt = seenAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, label, note, excerpt, ref, state
        case seenAt = "seen_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        rawKind = try? c.decodeIfPresent(String.self, forKey: .kind)
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? ""
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil
        excerpt = (try? c.decodeIfPresent(String.self, forKey: .excerpt)) ?? nil
        ref = (try? c.decodeIfPresent(SourceRef.self, forKey: .ref)) ?? nil
        // A state this app does not know reads as the weakest claim the agent can make.
        state = ((try? c.decodeIfPresent(String.self, forKey: .state)).flatMap { $0 }).flatMap(SourceState.init(rawValue:)) ?? .stated
        seenAt = (try? c.decodeIfPresent(String.self, forKey: .seenAt)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(rawKind, forKey: .kind)
        try c.encode(label, forKey: .label)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(excerpt, forKey: .excerpt)
        try c.encode(state.rawValue, forKey: .state)
        try c.encodeIfPresent(seenAt, forKey: .seenAt)
    }
}

/// A list that drops the elements that do not decode.
struct LossyList<Element: Decodable>: Decodable {
    let elements: [Element]

    private struct Slot: Decodable {
        let value: Element?
        init(from decoder: Decoder) throws { value = try? Element(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        elements = (try? decoder.singleValueContainer().decode([Slot].self))?.compactMap(\.value) ?? []
    }
}

/// The markers `[[s:ID,ID2]]` in agent text.
enum SourceMarkers {
    /// Stands for one marker in a text that is being laid out. Private use, so no agent text holds it.
    static let placeholder: Character = "\u{E000}"

    private static let closed = try! NSRegularExpression(pattern: #"[ \t]*\[\[s:([^\[\]\n]*)\]\]"#)
    /// A marker cut off at the end of the text.
    private static let open = try! NSRegularExpression(pattern: #"[ \t]*\[\[s:[^\[\]]*$"#)

    static func ids(in raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The text with every marker gone, and the space before it. No raw `[[s:` is left.
    static func strip(_ text: String) -> String {
        guard text.contains("[[s:") else { return text }
        return replacing(text) { _ in "" }.text
    }

    struct Parsed: Equatable {
        /// The text with a `placeholder` where each marker stood.
        var text: String
        /// The ids of each marker, in order.
        var groups: [[String]]
    }

    static func parse(_ text: String) -> Parsed {
        guard text.contains("[[s:") else { return Parsed(text: text, groups: []) }
        let result = replacing(text) { String(placeholder) + $0 }
        return Parsed(text: result.text, groups: result.groups)
    }

    /// `text` with one marker for each id added at the end, so each uncited source shows as its own pill (WAG-359).
    static func appending(uncited ids: [String], to text: String) -> String {
        guard !ids.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) + ids.map { " [[s:\($0)]]" }.joined()
    }

    /// Puts the markers back where `parse` put placeholders.
    static func restore(_ text: String, groups: [[String]]) -> String {
        var out = ""
        var index = 0
        for character in text {
            if character == placeholder {
                if index < groups.count { out += "[[s:" + groups[index].joined(separator: ",") + "]]" }
                index += 1
            } else {
                out.append(character)
            }
        }
        return out
    }

    /// The pieces of a text in order: words and markers.
    enum Segment: Equatable {
        case text(String)
        case marker([String])
    }

    static func segments(_ text: String) -> [Segment] {
        let parsed = parse(text)
        var out: [Segment] = []
        var current = ""
        var index = 0
        for character in parsed.text {
            if character == placeholder {
                if !current.isEmpty { out.append(.text(current)) }
                current = ""
                out.append(.marker(index < parsed.groups.count ? parsed.groups[index] : []))
                index += 1
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { out.append(.text(current)) }
        return out
    }

    private static func replacing(_ text: String, with make: (String) -> String) -> (text: String, groups: [[String]]) {
        var groups: [[String]] = []
        var out = ""
        let ns = text as NSString
        var cursor = 0
        for match in closed.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let ids = ids(in: ns.substring(with: match.range(at: 1)))
            groups.append(ids)
            out += make("")
            cursor = match.range.upperBound
        }
        out += ns.substring(from: cursor)
        let rest = out as NSString
        if let cut = open.firstMatch(in: out, range: NSRange(location: 0, length: rest.length)) {
            out = rest.substring(to: cut.range.location)
        }
        return (out, groups)
    }
}

/// What a pill draws: the first source, and how many more a grouped marker cites.
struct SourcePillModel: Equatable {
    let sources: [Source]
    var first: Source { sources[0] }
    var extra: Int { sources.count - 1 }
    var label: String { first.label }
    var kind: SourceKind { first.drawnKind }
    var state: SourceState { first.state }
    /// The "+N" after the label, nil for one source.
    var extraText: String? { extra > 0 ? "+\(extra)" : nil }
}

/// The sources of the round on screen.
struct SourceBook: Equatable {
    let sources: [Source]
    /// When the round was asked, for "3 min before the request".
    let askedAt: Date?
    /// WAG-359: ids of the sources that no marker cites in any text of the round, in the order sent. The request
    /// page shows them as pills at the end of the why text (else of the need).
    let uncited: [String]

    static let empty = SourceBook(sources: [], askedAt: nil)

    init(sources: [Source], askedAt: Date? = nil, citedIn texts: [String]? = nil) {
        // The first source with an id wins; a repeat is dropped.
        var seen = Set<String>()
        let kept = sources.filter { seen.insert($0.id).inserted }
        self.sources = kept
        self.askedAt = askedAt
        self.uncited = texts.map { Self.uncitedIds(sources: kept, texts: $0) } ?? []
    }

    /// The ids of `sources` that no marker in `texts` names, in the order sent.
    static func uncitedIds(sources: [Source], texts: [String]) -> [String] {
        var cited = Set<String>()
        for text in texts where text.contains("[[s:") {
            for group in SourceMarkers.parse(text).groups { cited.formUnion(group) }
        }
        return sources.map(\.id).filter { !cited.contains($0) }
    }

    var isEmpty: Bool { sources.isEmpty }

    func source(id: String) -> Source? { sources.first { $0.id == id } }

    /// The pill for one marker. Ids this round does not hold are left out; none left gives `nil` (no pill).
    func pill(ids: [String]) -> SourcePillModel? {
        var seen = Set<String>()
        let found = ids.compactMap { source(id: $0) }.filter { seen.insert($0.id).inserted }
        return found.isEmpty ? nil : SourcePillModel(sources: found)
    }

    /// The parsed text, or `nil` when no marker of it names a source of the round: it shows as plain text.
    func parsedWithPills(_ text: String) -> SourceMarkers.Parsed? {
        let parsed = SourceMarkers.parse(text)
        return parsed.groups.contains { pill(ids: $0) != nil } ? parsed : nil
    }

    /// The sub-line of the list: "7 sources · 5 seen by Waggle · 1 stated by the agent · 1 not checked".
    /// A part with a count of 0 is left out.
    var summary: String {
        let seen = sources.filter { $0.state == .seen }.count
        let stated = sources.filter { $0.state == .stated }.count
        let unchecked = sources.filter { $0.state == .assumption }.count
        var parts = ["\(sources.count) \(sources.count == 1 ? "source" : "sources")"]
        if seen > 0 { parts.append("\(seen) seen by Waggle") }
        if stated > 0 { parts.append("\(stated) stated by the agent") }
        if unchecked > 0 { parts.append("\(unchecked) not checked") }
        return parts.joined(separator: " · ")
    }

    /// The label of the button.
    var buttonText: String { "Sources · \(sources.count)" }

    /// The first three distinct kinds, for the dots on the button.
    var dotKinds: [SourceKind] {
        var kinds: [SourceKind] = []
        for source in sources where !kinds.contains(source.drawnKind) {
            kinds.append(source.drawnKind)
            if kinds.count == 3 { break }
        }
        return kinds
    }

    /// The "when" line of a card or an open row.
    func whenLine(for source: Source) -> String {
        switch source.state {
        case .assumption: return "The agent did not check this"
        case .stated: return "Waggle found no matching call in the session"
        case .seen:
            guard let seenAt = source.seenAt.flatMap(KnockDateFormat.parse), let askedAt else { return "Ran in this session" }
            return "Ran in this session, \(Self.span(from: seenAt, to: askedAt)) the request"
        }
    }

    /// "3 min before", "2 h before", "just before"; "after" when it ran later.
    static func span(from seen: Date, to asked: Date) -> String {
        let seconds = asked.timeIntervalSince(seen)
        let word = seconds >= 0 ? "before" : "after"
        let minutes = Int((abs(seconds) / 60).rounded())
        if minutes < 1 { return "just \(word)" }
        if minutes < 60 { return "\(minutes) min \(word)" }
        let hours = Int((Double(minutes) / 60).rounded())
        if hours < 48 { return "\(hours) h \(word)" }
        return "\(Int((Double(hours) / 24).rounded())) days \(word)"
    }

    /// The state mark of a card: "Seen by Waggle", "Stated by the agent", "Not checked".
    static func stateWord(_ state: SourceState) -> String {
        switch state {
        case .seen: "Seen by Waggle"
        case .stated: "Stated by the agent"
        case .assumption: "Not checked"
        }
    }
}

extension Round {
    /// The sources of this round as a book.
    var sourceBook: SourceBook {
        SourceBook(sources: sources, askedAt: KnockDateFormat.parse(createdAt))
    }

    /// Every agent text of this round that can hold a marker (WAG-359).
    var markedTexts: [String] {
        var out = [question]
        for item in items {
            out += [item.question, item.recommendationWhy].compactMap { $0 }
            for option in item.options { out += [option.label] + option.pros + option.cons + option.effects }
        }
        return out
    }
}

extension CaseDetail {
    /// The sources of the newest round: the text on screen is the newest round's.
    var currentSourceBook: SourceBook {
        if let round = rounds?.max(by: { $0.seq < $1.seq }), !round.sources.isEmpty {
            let texts = round.markedTexts + [self.case.need, self.case.currentWhy].compactMap { $0 }
            return SourceBook(sources: round.sources, askedAt: KnockDateFormat.parse(round.createdAt), citedIn: texts)
        }
        // Evidence builds only: sources from a file, for a daemon that does not serve them yet.
        let evidence = EvidenceSources.sources(forTitle: self.case.title)
        return evidence.isEmpty
            ? .empty
            : SourceBook(sources: evidence, askedAt: KnockDateFormat.parse(self.case.createdAt), citedIn: [self.case.need, self.case.currentWhy].compactMap { $0 })
    }
}

/// The "no sources" layout rule: a round with none shows no button, no pill and adds no spacing.
enum SourcesLayout {
    static func showsButton(_ book: SourceBook?) -> Bool { !(book?.isEmpty ?? true) }
}

/// WAG-407: the web address of a source, ready to show and to open. Only a plain http or https address with a host
/// and no user:password gets through. Anything else is `nil`, and the app never opens a string it did not parse here.
struct SourceLink: Equatable, Sendable {
    let url: URL
    let host: String

    init?(_ raw: String?) {
        guard let raw, !raw.isEmpty,
              raw.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let parts = URLComponents(string: raw),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              parts.user == nil, parts.password == nil,
              let host = parts.host, !host.isEmpty,
              let url = parts.url
        else { return nil }
        self.url = url
        self.host = host
    }
}
