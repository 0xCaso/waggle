import Foundation

extension QuestionPoint {
    /// Lean and rule out (WAG-326) need an option the wire can name: a pick-one or pick-several point that came
    /// from an item. A point of the older questions shape has no wire for them.
    var canDiscuss: Bool { isItem && select != .reply }
}

/// What a point shows, in the model of a single decision (WAG-326): the same option rows and the same page
/// block, so one request with several items reads like several single decisions.
extension QuestionsDocModel {
    /// One option row of a point, with every flag the single decision's row (`CompactOptionRow`) takes.
    struct OptionRow: Equatable {
        let position: Int
        let title: String
        let pros: [String]
        let cons: [String]
        var effects: [String] = []
        let isRecommended: Bool
        let isSelected: Bool
        let isLeaning: Bool
        let isRuledOut: Bool
        /// The why of the recommendation, on the recommended row only.
        let note: String?
        /// The row shows the lean and rule-out icons.
        let canDiscuss: Bool
        /// An unticked row of a pick-several point whose ticks reached `max`.
        var isLimitDimmed = false
        /// Task 11b: the facts, the points with their gists, and the option's full text under its title.
        var facts: [String] = []
        var proPoints: [OptionPoint] = []
        var conPoints: [OptionPoint] = []
        var description: String? = nil
    }

    func optionRows(question: String, point: QuestionPoint) -> [OptionRow] {
        let draft = draft(question, point.id)
        let why = point.recommendationWhy.map(AgentMarkdown.singleLine).flatMap { $0.isEmpty ? nil : $0 }
        return point.choices.enumerated().map { index, option in
            let isRecommended = point.recommended.contains(option.label)
            return OptionRow(
                position: index + 1, title: option.label, pros: option.pros, cons: option.cons, effects: option.effects,
                isRecommended: isRecommended,
                isSelected: point.select == .many ? draft.choices.contains(option.label) : draft.choice == option.label,
                isLeaning: draft.leaning.contains(option.label), isRuledOut: draft.ruledOut.contains(option.label),
                note: isRecommended ? why : option.why.map(AgentMarkdown.singleLine).flatMap { $0.isEmpty ? nil : $0 },
                canDiscuss: point.canDiscuss && !isLocked,
                isLimitDimmed: !isLocked && isAtLimit(point, draft) && !draft.choices.contains(option.label),
                facts: option.facts, proPoints: option.proPoints, conPoints: option.conPoints, description: option.detail)
        }
    }

    /// The card of a point in the page: the pick, or before a pick the recommendation, with its why.
    struct PointBlock: Equatable {
        let label: String
        let title: String?
        let pros: [String]
        let cons: [String]
        var effects: [String] = []
        let note: String?
        let noteTitle: String
        let swapId: String
        /// WAG-357: the item and option the card speaks of.
        var itemId: String? = nil
        var optionId: String? = nil
    }

    /// The block of a point. `pointNumber` is the point's place in its question when the question has several.
    /// A pick-one point shows its pick ("YOUR PICK · 2"), else its recommendation ("RECOMMENDED · 2"). A
    /// pick-several point shows its recommended options. A reply point shows the suggested reply. A point with
    /// no recommendation and no pick has none.
    func pointBlock(question: Question, point: QuestionPoint, pointNumber: Int? = nil) -> PointBlock? {
        let draft = draft(question.id, point.id)
        let suffix = pointNumber.map { "POINT \($0)" }
        let why = point.recommendationWhy.map(AgentMarkdown.singleLine).flatMap { $0.isEmpty ? nil : $0 }
        switch point.select {
        case .one:
            if let pick = CalmOption.pointPick(point, choice: draft.choice) {
                let isRecommended = point.recommended.contains(pick.option.label)
                return PointBlock(
                    label: CalmOption.blockLabel(position: pick.position, isPick: true, suffix: suffix), title: pick.option.label,
                    pros: pick.option.pros, cons: pick.option.cons, effects: pick.option.effects, note: isRecommended ? why : nil,
                    noteTitle: CalmNoteView.title(isRecommended: isRecommended), swapId: "\(point.id)-\(pick.option.id)",
                    itemId: point.itemId ?? point.id, optionId: pick.option.optionId)
            }
            if let label = point.recommended.first, let index = point.choices.firstIndex(where: { $0.label == label }) {
                let option = point.choices[index]
                return PointBlock(
                    label: CalmOption.blockLabel(position: index + 1, isPick: false, suffix: suffix), title: option.label,
                    pros: option.pros, cons: option.cons, effects: option.effects, note: why, noteTitle: CalmNoteView.title(isRecommended: true),
                    swapId: "\(point.id)-\(option.id)-rec", itemId: point.itemId ?? point.id, optionId: option.optionId)
            }
        case .many:
            let positions = point.choices.enumerated().filter { point.recommended.contains($0.element.label) }
            // The card shows until the person ticks; their own ticks then stand (WAG-334, as a single request).
            guard !positions.isEmpty, draft.choices.isEmpty else { break }
            return PointBlock(
                label: ["RECOMMENDED", PromptBarLogic.positionList(positions.map { $0.offset + 1 }), suffix].compactMap { $0 }.joined(separator: " · "),
                title: positions.map(\.element.label).joined(separator: ", "), pros: [], cons: [], note: why,
                noteTitle: CalmNoteView.title(isRecommended: true), swapId: "\(point.id)-rec", itemId: point.itemId ?? point.id)
        case .reply:
            guard let suggestion = point.recommended.first else { break }
            return PointBlock(
                label: ["RECOMMENDED", suffix].compactMap { $0 }.joined(separator: " · "), title: AgentMarkdown.singleLine(suggestion),
                pros: [], cons: [], note: why, noteTitle: CalmNoteView.title(isRecommended: true), swapId: "\(point.id)-rec",
                itemId: point.itemId ?? point.id)
        }
        return nil
    }

    /// The card of an older ask's free-text recommendation: only on the first point, where it shows once as the why.
    func legacyBlock(question: Question, point: QuestionPoint) -> PointBlock? {
        guard let legacyWhy, questions.first?.id == question.id, question.points.first?.id == point.id else { return nil }
        return PointBlock(label: "RECOMMENDED", title: nil, pros: [], cons: [], note: legacyWhy, noteTitle: CalmNoteView.title(isRecommended: true), swapId: "\(point.id)-legacy")
    }

    /// The cards of one point, in page order: the older ask's why (first point only), then the pick or recommendation.
    func blocks(question: Question, point: QuestionPoint, pointNumber: Int? = nil) -> [PointBlock] {
        [legacyBlock(question: question, point: point), pointBlock(question: question, point: point, pointNumber: pointNumber)].compactMap { $0 }
    }

    /// The cards under a point's rows on the page: the older ask's why and a reply's suggested text. The pick or
    /// recommendation card of a pick-one or pick-several point is left out: its rows already show the
    /// Recommended pill, the Your answer tag and the why (C3, options show once).
    func pageBlocks(question: Question, point: QuestionPoint, pointNumber: Int? = nil) -> [PointBlock] {
        let reply = point.select == .reply ? pointBlock(question: question, point: point, pointNumber: pointNumber) : nil
        return [legacyBlock(question: question, point: point), reply].compactMap { $0 }
    }

    /// `pageBlocks` for every point of a question, in page order.
    func pagePointBlocks(of question: Question) -> [PointBlock] {
        question.points.enumerated().flatMap { index, point in
            pageBlocks(question: question, point: point, pointNumber: question.points.count > 1 ? index + 1 : nil)
        }
    }

    /// The cards of a question's points, in page order.
    func pointBlocks(of question: Question) -> [PointBlock] {
        question.points.enumerated().flatMap { index, point in
            blocks(question: question, point: point, pointNumber: question.points.count > 1 ? index + 1 : nil)
        }
    }

    /// The why of an older questions ask (WAG-326): its free-text recommendation and its why, as one text. The
    /// daemon turns its questions into items with no recommendation of their own, so the ask-level text is the only
    /// one. `nil` when both are empty, or when an item has a recommendation of its own.
    static func legacyWhy(of request: Case) -> String? {
        guard !request.items.contains(where: { !$0.recommendation.isEmpty }) else { return nil }
        let lead = request.recommendation.trimmingCharacters(in: .whitespacesAndNewlines)
        let why = request.recommendationWhy.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = ReviewRows.join(lead, why)
        let line = AgentMarkdown.singleLine(text)
        return line.isEmpty ? nil : line
    }
}
