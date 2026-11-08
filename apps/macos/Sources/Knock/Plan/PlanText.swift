import Foundation

/// The words and the small decisions of a plan ask (HAIL-151), as pure code so they are tested
/// without hosting a view. The daemon has the same stage line (`planStageLine`), so the queue row
/// and the phone read alike.
enum PlanText {
    /// How a stage shows in the track.
    enum TrackState: Equatable {
        case done
        case current
        case upcoming
    }

    static func title(_ name: PlanStageName) -> String {
        switch name {
        case .questions: "Questions"
        case .approaches: "Approaches"
        case .design: "Design"
        case .spec: "Spec"
        }
    }

    /// The four stages in order, each with its state for a case whose newest round is at `current`.
    static func track(current: PlanStageName) -> [(name: PlanStageName, state: TrackState)] {
        let all = PlanStageName.allCases
        let at = all.firstIndex(of: current) ?? 0
        return all.enumerated().map { index, name in
            (name, index < at ? .done : (index == at ? .current : .upcoming))
        }
    }

    /// "Brainstorm · question 3 of ~5", "Design · section 1 of 3", "Spec · ready for review".
    static func stageLine(_ stage: PlanStage) -> String {
        func count(_ noun: String) -> String {
            guard let step = stage.step else { return "" }
            let total = stage.total.map { " of \(stage.totalIsEstimate == true ? "~" : "")\($0)" } ?? ""
            return " · \(noun) \(step)\(total)"
        }
        switch stage.name {
        case .questions: return "Brainstorm\(count("question"))"
        case .approaches: return "Approaches · pick one"
        case .design: return "Design\(count("section"))"
        case .spec: return "Spec · ready for review"
        }
    }

    /// The small caps line over the question in the right column: "Question 3 of ~5".
    static func progressLabel(_ stage: PlanStage) -> String {
        func count(_ noun: String) -> String {
            guard let step = stage.step else { return noun }
            let total = stage.total.map { " of \(stage.totalIsEstimate == true ? "~" : "")\($0)" } ?? ""
            return "\(noun) \(step)\(total)"
        }
        switch stage.name {
        case .questions: return count("Question")
        case .approaches: return "Approaches"
        case .design: return count("Design · section")
        case .spec: return "Spec"
        }
    }

    /// The chip that takes the artifact chip's place on a plan row: "Plan · round 3".
    static func roundChip(rounds: Int) -> String { "Plan · round \(rounds)" }

    /// The primary button for a stage's round.
    static func primaryLabel(_ name: PlanStageName) -> String {
        switch name {
        case .questions: "Next question"
        case .approaches: "Use this approach"
        case .design: "Approve section"
        case .spec: "Approve and start planning"
        }
    }

    /// The primary button's short words, for a row too narrow for the full label.
    static func shortPrimaryLabel(_ name: PlanStageName) -> String {
        switch name {
        case .questions: "Next"
        case .approaches: "Use this"
        case .design, .spec: "Approve"
        }
    }

    /// The second button; only the design and spec stages have one.
    static func secondaryLabel(_ name: PlanStageName) -> String? {
        switch name {
        case .design: "Change"
        case .spec: "Request changes"
        case .questions, .approaches: nil
        }
    }

    /// True when an option of the round already means "change this" ("Changes", "Request changes", "Change the layout").
    static func hasChangesOption(_ options: [Option]) -> Bool {
        options.contains { option in
            let title = AgentMarkdown.singleLine(option.displayTitle).lowercased()
            return title.hasPrefix("change") || title.hasPrefix("request change") || title.hasPrefix("needs change")
        }
    }

    /// The field's placeholder after "Change" / "Request changes" was pressed with no note (WAG-336).
    static let whatShouldChange = "What should change?"

    /// What the secondary button sends: the person's note with a plain prefix the agent cannot misread.
    static func changeMessage(stage name: PlanStageName, note: String) -> String {
        let prefix = name == .spec ? "Changes requested to the spec:" : "Change requested to this section:"
        return "\(prefix) \(note)"
    }

    /// "2 answered".
    static func answeredLabel(_ count: Int) -> String { "\(count) answered" }

    /// The rounds before the newest one that the person answered: the fold's content.
    static func earlierAnswered(_ rounds: [PlanRound]) -> [PlanRound] {
        guard let last = rounds.last else { return [] }
        return rounds.filter { $0.answer != nil && $0.seq != last.seq }
    }

    /// The answer of a round in plain words: the chosen option's title, or the person's own words.
    static func answerSummary(_ round: PlanRound) -> String {
        guard let answer = round.answer else { return "" }
        let titles = (answer.choices ?? answer.choice.map { [$0] } ?? []).map { id in
            round.options.first(where: { $0.id == id })?.displayTitle ?? id
        }
        var parts: [String] = []
        if !titles.isEmpty { parts.append(titles.joined(separator: ", ")) }
        if let message = answer.message, !message.isEmpty { parts.append(AgentMarkdown.singleLine(message)) }
        return parts.isEmpty ? "Answered" : parts.joined(separator: " · ")
    }

    /// The question the current round asks: the newest round's, else the ask's own need.
    static func currentQuestion(for knockCase: Case, rounds: [PlanRound]?) -> String {
        if let question = rounds?.last?.question, !question.isEmpty { return question }
        return knockCase.need
    }

    /// A round's text read like a readme (operator, 4 Oct): a short headline, then the details.
    struct QuestionParts: Equatable {
        /// The bold line under the stage track. Empty when the text opens with a list.
        var headline: String
        /// Everything after the headline, as safe markdown in regular weight. Nil when there is none.
        var body: String?
    }

    /// Splits a round's text. The headline is the first sentence of the first paragraph (a heading
    /// line counts whole), so a one-line question reads as today; the rest of that paragraph and
    /// every later block become the body. A text that opens with a list has no headline.
    static func questionParts(_ text: String) -> QuestionParts {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        func rest(from index: Int) -> String? {
            guard index < lines.count else { return nil }
            let out = lines[index...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return out.isEmpty ? nil : out
        }
        guard let start = trimmed.firstIndex(where: { !$0.isEmpty }) else { return QuestionParts(headline: "", body: nil) }
        if AgentMarkdown.listMarker(trimmed[start]) != nil {
            return QuestionParts(headline: "", body: rest(from: start))
        }
        if let heading = AgentMarkdown.headingText(trimmed[start]) {
            return QuestionParts(headline: heading, body: rest(from: start + 1))
        }
        var end = start
        while end < trimmed.count, !trimmed[end].isEmpty, AgentMarkdown.listMarker(trimmed[end]) == nil,
            AgentMarkdown.headingText(trimmed[end]) == nil
        {
            end += 1
        }
        let paragraph = trimmed[start..<end].joined(separator: " ")
        let after = rest(from: end)
        guard let cut = firstSentenceEnd(paragraph) else { return QuestionParts(headline: paragraph, body: after) }
        let headline = String(paragraph[..<cut]).trimmingCharacters(in: .whitespaces)
        let tail = String(paragraph[cut...]).trimmingCharacters(in: .whitespaces)
        let body = [tail.isEmpty ? nil : tail, after].compactMap { $0 }.joined(separator: "\n\n")
        return QuestionParts(headline: headline, body: body.isEmpty ? nil : body)
    }

    private static let abbreviations: Set<String> = ["e.g", "i.e", "etc", "vs", "cf", "approx", "mr", "mrs", "ms", "dr", "no"]

    /// Where the first sentence of `paragraph` ends, when more text follows it: after a ".", "?" or
    /// "!" (and any closing `*`, `_`, `)`, quote or backtick) that a space follows. Never inside
    /// inline code or bold, and never after a common abbreviation or a single letter.
    static func firstSentenceEnd(_ paragraph: String) -> String.Index? {
        var index = paragraph.startIndex
        while index < paragraph.endIndex {
            let char = paragraph[index]
            defer { index = paragraph.index(after: index) }
            guard ".?!".contains(char) else { continue }
            var end = paragraph.index(after: index)
            while end < paragraph.endIndex, "*_)\"'\u{201D}\u{2019}`".contains(paragraph[end]) {
                end = paragraph.index(after: end)
            }
            guard end < paragraph.endIndex, paragraph[end].isWhitespace else { continue }
            let before = String(paragraph[..<end])
            let stars = before.filter { $0 == "*" }.count
            let bolds = before.components(separatedBy: "**").count - 1
            guard before.filter({ $0 == "`" }).count % 2 == 0, bolds % 2 == 0, (stars - 2 * bolds) % 2 == 0 else {
                continue
            }
            if char == "." {
                let word = paragraph[..<index].split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
                let bare = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "(*_\"'"))
                if abbreviations.contains(bare) || bare.count == 1 { continue }
            }
            return end
        }
        return nil
    }
}

extension Case {
    /// The time the queue sorts a case by: a plan ask sorts by its latest round (HAIL-151), any other
    /// ask by when it arrived.
    var sortDate: Date {
        (plan != nil ? updatedAtDate : createdAtDate) ?? createdAtDate ?? .distantPast
    }
}

/// Which form the four-stage track takes in a given width (HAIL-157). Pure code, so the breakpoints are
/// tested without hosting a view. Widest first: `full` (every label), `circles` (all four circles, a label
/// on the current stage only), `line` ("Stage 2 of 4 · Approaches" with four small dots).
enum PlanTrackLayout {
    enum Form: Equatable, CaseIterable {
        case full
        case circles
        case line
    }

    /// The two tracks that draw the stages: the right column's numbered circles and the queue row's chips.
    enum Style {
        case numbered
        case chips
    }

    /// Width of one text run, estimated per character. Slightly high on purpose: a form that is a few
    /// points too wide only costs a step down; a form that is too narrow would clip.
    private static func text(_ string: String, perChar: Double) -> Double {
        Double(string.count) * perChar
    }

    /// The width a form needs, in points.
    static func requiredWidth(_ form: Form, style: Style, stage: PlanStageName) -> Double {
        let names = PlanStageName.allCases
        switch (style, form) {
        case (.numbered, .full):
            // circle 20 + gap 6 + label, and three joins of at least 8 + 12 padding.
            let labels = names.map { text(PlanText.title($0), perChar: $0 == stage ? 7.2 : 6.6) + 26 }
            return labels.reduce(0, +) + 3 * 20
        case (.numbered, .circles):
            // four circles of 20, three joins of at least 6 + 8, then the current label.
            return 80 + 3 * 14 + 6 + text(PlanText.title(stage), perChar: 7.2)
        case (.chips, .full):
            // chip: padding 14 + tick 10 (done only) + label; 4 between chips.
            let at = names.firstIndex(of: stage) ?? 0
            let chips = names.enumerated().map { index, name in
                text(PlanText.title(name), perChar: 6.0) + 14 + (index < at ? 10 : 0)
            }
            return chips.reduce(0, +) + 3 * 4
        case (.chips, .circles):
            // four circles of 18, 4 between, then the current label.
            return 72 + 3 * 4 + 6 + text(PlanText.title(stage), perChar: 6.4)
        case (_, .line):
            return text(line(stage), perChar: 6.6) + 8 + 4 * 6 + 3 * 4
        }
    }

    /// "Stage 2 of 4 · Approaches".
    static func line(_ stage: PlanStageName) -> String {
        let index = (PlanStageName.allCases.firstIndex(of: stage) ?? 0) + 1
        return "Stage \(index) of \(PlanStageName.allCases.count) · \(PlanText.title(stage))"
    }

    /// The widest form that fits `width`. The line form is the floor: it is the shortest, and the view
    /// scrolls sideways if even that does not fit.
    static func form(width: Double, style: Style, stage: PlanStageName) -> Form {
        for form in [Form.full, .circles] where requiredWidth(form, style: style, stage: stage) <= width {
            return form
        }
        return .line
    }
}
