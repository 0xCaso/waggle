import Foundation

/// What the decision doc shows for an ask with questions (WAG-257, from WAG-252): the answers so far,
/// the variant picked for each question, progress and the bottom bar. Pure rules, no views.
struct QuestionsDocModel: Equatable {
    struct Key: Hashable {
        let questionId: String
        let pointId: String
    }

    struct Draft: Equatable {
        /// The label picked on a pick-one point.
        var choice: String?
        /// The labels ticked on a pick-several point, in the order they were ticked.
        var choices: [String] = []
        /// The written answer of a reply point.
        var text = ""
        var note = ""
        /// The labels leaned to and ruled out on a point (WAG-326), as on a single decision.
        var leaning: [String] = []
        var ruledOut: [String] = []
    }

    /// The round a request is in: its number and its questions.
    private struct RoundMark: Equatable {
        let round: Int
        let questions: [Question]
    }

    let caseId: String
    let questions: [Question]
    /// True when the steps come from `Case.items` (WAG-315): the answers go back as `item_answers`, and every
    /// item needs an answer to send them.
    let usesItems: Bool
    /// The free-text recommendation of an older questions ask (WAG-326, operator decision WAG-310): it names
    /// no option, so it shows once, as the why, on the first point.
    let legacyWhy: String?
    /// True once the answers went out: the page shows them and no longer edits.
    private(set) var isLocked: Bool
    /// Which round the request was in, as last seen, and the round the page was locked on (WAG-346). A locked
    /// page that gets a needs-you request of another round is a new round, not the daemon catching up.
    private var seen: RoundMark
    private var lockedOn: RoundMark?
    /// WAG-383: the agent's newest message when the page was last built, and when it locked. An agent that answers
    /// "more detail" with a message only keeps the round: a newer message on it opens the page again.
    private var seenUpdate: String?
    private var lockedUpdate: String?
    private(set) var drafts: [Key: Draft] = [:]
    /// The variant picked for a question. A question with no entry shows its first variant.
    private(set) var variants: [String: String] = [:]
    var note = ""
    /// The step the page shows (WAG-287): `0..<questions.count` is a question, `questions.count` is the review.
    /// An ask with two or more questions goes step by step, and so does one with several items.
    private(set) var step = 0

    /// `itemAnswers` are the answers of the reply that was sent, by item id (a request with items).
    init(request: Case, itemAnswers: [ItemAnswer] = []) {
        caseId = request.id
        questions = request.docQuestions
        usesItems = request.docUsesItems
        legacyWhy = Self.legacyWhy(of: request)
        isLocked = request.status != .needsYou
        seen = RoundMark(round: request.roundNumber, questions: request.docQuestions)
        lockedOn = isLocked ? seen : nil
        seenUpdate = request.latestUpdateAt
        lockedUpdate = isLocked ? seenUpdate : nil
        if isLocked {
            if usesItems {
                for answer in itemAnswers { restore(answer) }
            } else {
                for answer in request.latestReplyAnswers {
                    drafts[Key(questionId: answer.questionId, pointId: answer.pointId)] = Draft(choice: answer.choice, note: answer.note ?? "")
                }
            }
            note = request.latestReplyMessage ?? ""
            // A sent ask opens on its summary.
            if isStepped { step = questions.count }
        }
    }

    /// Turns a sent item answer back into a draft: option ids become the labels the rows show.
    private mutating func restore(_ answer: ItemAnswer) {
        for question in questions {
            guard let point = question.points.first(where: { $0.itemId == answer.itemId }) else { continue }
            func label(_ id: String) -> String? { point.choices.first { $0.optionId == id }?.label }
            var draft = Draft(note: answer.note ?? "")
            draft.choice = answer.choice.flatMap(label)
            draft.choices = (answer.choices ?? []).compactMap(label)
            draft.text = answer.text ?? ""
            drafts[Key(questionId: question.id, pointId: point.id)] = draft
            return
        }
    }

    /// The same request with fresh data: your answers, variants and note stay. Another request starts clean.
    mutating func refresh(with request: Case, itemAnswers: [ItemAnswer] = []) {
        guard request.id == caseId else { self = Self(request: request, itemAnswers: itemAnswers); return }
        // Sent here, and the daemon's data has not caught up yet (same round): keep what the page shows.
        // Another round opens fresh, unlocked, on its new questions.
        if isLocked {
            if request.status == .needsYou, lockedOn == RoundMark(round: request.roundNumber, questions: request.docQuestions),
               request.latestUpdateAt == lockedUpdate { return }
            self = Self(request: request, itemAnswers: itemAnswers)
            return
        }
        let keep = self
        self = Self(request: request, itemAnswers: itemAnswers)
        guard !isLocked else { return }
        // WAG-364: a draft kept under the step id of an old group page moves to the step of its item (point ids are
        // item ids). A draft whose item is gone is dropped.
        for (key, draft) in keep.drafts {
            if point(key) != nil {
                drafts[key] = draft
            } else if usesItems, let question = questions.first(where: { $0.points.contains { $0.id == key.pointId } }) {
                drafts[Key(questionId: question.id, pointId: key.pointId)] = draft
            }
        }
        variants = keep.variants
        note = keep.note
        step = min(keep.step, reviewStep)
    }

    /// Opens the answers again ("Change answer"): the sent answers become drafts you can edit.
    mutating func unlock() { isLocked = false }

    private func point(_ key: Key) -> QuestionPoint? {
        questions.first { $0.id == key.questionId }?.points.first { $0.id == key.pointId }
    }

    // MARK: Answers

    func draft(_ questionId: String, _ pointId: String) -> Draft {
        drafts[Key(questionId: questionId, pointId: pointId)] ?? Draft()
    }

    /// Picks a choice by its label. Picking the chosen one again clears it.
    mutating func choose(_ choice: String, question: String, point: String) {
        guard !isLocked, let found = self.point(Key(questionId: question, pointId: point)), found.choiceLabels.contains(choice) else { return }
        let key = Key(questionId: question, pointId: point)
        var draft = drafts[key] ?? Draft()
        // A pick is a decision: it takes back a lean or rule-out on that option (WAG-326).
        draft.leaning.removeAll { $0 == choice }
        draft.ruledOut.removeAll { $0 == choice }
        if found.select == .many {
            // A pick-several point ticks and unticks, as a single request does (WAG-334): at `max` an unticked
            // row does nothing until the person unticks another.
            if let index = draft.choices.firstIndex(of: choice) {
                draft.choices.remove(at: index)
            } else if !isAtLimit(found, draft) {
                draft.choices.append(choice)
            }
        } else {
            draft.choice = draft.choice == choice ? nil : choice
        }
        drafts[key] = draft
    }

    // MARK: Pick several (WAG-334)

    /// The ticks reached `max`: unticked rows dim and do not toggle, as in a single request.
    func isAtLimit(_ point: QuestionPoint, _ draft: Draft) -> Bool {
        point.select == .many && (point.max.map { draft.choices.count >= $0 } ?? false)
    }

    /// The recommended options are not all ticked yet, so "Tick the recommended" still has work to do.
    func canTickRecommended(_ point: QuestionPoint, question: String) -> Bool {
        guard !isLocked, point.select == .many else { return false }
        let wanted = Self.recommendedTicks(point)
        return !wanted.isEmpty && Set(wanted) != Set(draft(question, point.id).choices)
    }

    /// The recommended labels of a pick-several point, cut to `max`, in the order of the options.
    private static func recommendedTicks(_ point: QuestionPoint) -> [String] {
        let ordered = point.choiceLabels.filter { point.recommended.contains($0) }
        return point.max.map { Array(ordered.prefix($0)) } ?? ordered
    }

    /// "Tick the recommended": the recommended options become the person's own ticks.
    mutating func tickRecommended(question: String, point: String) {
        let key = Key(questionId: question, pointId: point)
        guard !isLocked, let found = self.point(key), found.select == .many else { return }
        var draft = drafts[key] ?? Draft()
        draft.choices = Self.recommendedTicks(found)
        draft.leaning.removeAll { draft.choices.contains($0) }
        draft.ruledOut.removeAll { draft.choices.contains($0) }
        drafts[key] = draft
    }

    /// "Clear": takes every tick back.
    mutating func clearTicks(question: String, point: String) {
        let key = Key(questionId: question, pointId: point)
        guard !isLocked, drafts[key] != nil else { return }
        drafts[key]?.choices = []
    }

    // MARK: Keys (WAG-334)

    /// The point the number keys, Cmd-D and "?" act on in a step: the first point not answered yet that has
    /// rows to pick, else the first point with rows.
    var keyPoint: (question: Question, point: QuestionPoint)? {
        guard let question = currentQuestion else { return nil }
        let pickable = question.points.filter { $0.select != .reply }
        let found = pickable.first { !isAnswered(question: question, point: $0) } ?? pickable.first
        return found.map { (question, $0) }
    }

    /// The number key: picks (or ticks) the row at that position of the key point.
    mutating func pick(position: Int) {
        guard !isLocked, let (question, point) = keyPoint, position >= 1, position <= point.choices.count else { return }
        choose(point.choices[position - 1].label, question: question.id, point: point.id)
    }

    /// Cmd-D: takes the recommendation of the key point as the person's own pick. It sends nothing. A point
    /// with no recommendation does nothing.
    mutating func acceptRecommendation() {
        guard !isLocked, let (question, point) = keyPoint, !point.recommended.isEmpty else { return }
        if point.select == .many {
            tickRecommended(question: question.id, point: point.id)
        } else if let label = point.recommended.first, draft(question.id, point.id).choice != label {
            choose(label, question: question.id, point: point.id)
        }
    }

    // MARK: Lean and rule out (WAG-326)

    /// The half circle on an option row: leans to it, or takes the lean back. It clears the pick of that option
    /// and its rule-out, as on a single decision.
    mutating func toggleLean(_ label: String, question: String, point: String) {
        setMark(label, question: question, point: point, lean: true)
    }

    /// The × on an option row: rules it out, or takes it back. It clears the pick of that option and its lean.
    mutating func toggleRuleOut(_ label: String, question: String, point: String) {
        setMark(label, question: question, point: point, lean: false)
    }

    private mutating func setMark(_ label: String, question: String, point: String, lean: Bool) {
        let key = Key(questionId: question, pointId: point)
        guard !isLocked, let found = self.point(key), found.canDiscuss, found.choiceLabels.contains(label) else { return }
        var draft = drafts[key] ?? Draft()
        let wasOn = lean ? draft.leaning.contains(label) : draft.ruledOut.contains(label)
        draft.leaning.removeAll { $0 == label }
        draft.ruledOut.removeAll { $0 == label }
        if !wasOn {
            if lean { draft.leaning.append(label) } else { draft.ruledOut.append(label) }
        }
        if !wasOn {
            // A lean or rule-out is not a decision: it takes the pick back.
            if found.select == .many { draft.choices.removeAll { $0 == label } } else { draft.choice = nil }
        }
        drafts[key] = draft
    }

    /// The ids of the options leaned to, as the wire names them with several items: "<item id>/<option id>".
    var leaningIds: [String] { markIds(\.leaning) }
    var ruledOutIds: [String] { markIds(\.ruledOut) }

    private func markIds(_ marks: KeyPath<Draft, [String]>) -> [String] {
        questions.flatMap { question in
            question.points.flatMap { point -> [String] in
                guard let itemId = point.itemId else { return [] }
                return draft(question.id, point.id)[keyPath: marks].map { "\(itemId)/\(point.optionId(forLabel: $0))" }
            }
        }
    }

    var isDiscussing: Bool { !leaningIds.isEmpty || !ruledOutIds.isEmpty }

    /// A send is a lean or rule-out, not a decision, until every item is answered (the same words as a single decision).
    var sendsDiscuss: Bool { isDiscussing && !sendsAnswers }

    /// The written answer of a reply point.
    mutating func setText(_ text: String, question: String, point: String) {
        guard !isLocked, let found = self.point(Key(questionId: question, pointId: point)), found.select == .reply else { return }
        let key = Key(questionId: question, pointId: point)
        var draft = drafts[key] ?? Draft()
        draft.text = text
        drafts[key] = draft
    }

    /// A point is answered when it has a pick, a tick or some written text.
    func isAnswered(_ draft: Draft, _ point: QuestionPoint) -> Bool {
        switch point.select {
        case .one: return draft.choice != nil
        case .many: return !draft.choices.isEmpty
        case .reply: return !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func isAnswered(question: Question, point: QuestionPoint) -> Bool {
        isAnswered(draft(question.id, point.id), point)
    }

    // MARK: Steps (WAG-287)

    /// A decision with two or more questions shows one question at a time, and so does one with several items
    /// (one step per group, else per item).
    var isStepped: Bool { usesItems || questions.count >= 2 }

    /// The step after the last question: the summary and the one Send.
    var reviewStep: Int { questions.count }

    var isReview: Bool { isStepped && step == reviewStep }

    /// The question the step shows; `nil` on the review step and for an ask that is not stepped.
    var currentQuestion: Question? {
        isStepped && step < questions.count ? questions[step] : nil
    }

    var canGoBack: Bool { isStepped && step > 0 }

    mutating func next() { step = min(step + 1, reviewStep) }

    mutating func back() { step = max(step - 1, 0) }

    mutating func jump(to target: Int) { step = min(max(target, 0), reviewStep) }

    /// The need of the request shows on every question step (WAG-334), not the review step: a later step is
    /// never an empty page, and the page and the full size column agree.
    var showsDocNeed: Bool { currentQuestion != nil }

    /// "Ask for more detail" is the last row under the rows of a step, until the answers are sent (WAG-304).
    var showsAskForDetail: Bool { isStepped && !isReview && !isLocked }

    /// "Decision 2 of 3" for the crumb; the review step says "Review".
    var stepCrumb: String {
        isReview ? "Review" : "Decision \(step + 1) of \(questions.count)"
    }

    /// The positions (from 1, in the order of the options) of the options leaned to and ruled out on the
    /// current step (WAG-330). Empty off a step.
    var stepMarkPositions: (leaning: [Int], ruledOut: [Int]) {
        guard isStepped, let question = currentQuestion else { return ([], []) }
        var leaning: Set<Int> = []
        var ruledOut: Set<Int> = []
        for point in question.points {
            let draft = draft(question.id, point.id)
            let labels = point.choiceLabels
            leaning.formUnion(draft.leaning.compactMap { labels.firstIndex(of: $0).map { $0 + 1 } })
            ruledOut.formUnion(draft.ruledOut.compactMap { labels.firstIndex(of: $0).map { $0 + 1 } })
        }
        return (leaning.sorted(), ruledOut.sorted())
    }

    /// On a step, a typed note or a lean or rule-out on the step's item can go now as Keep talking, with the
    /// answers, leans and rule-outs given so far (WAG-330). Nothing typed and nothing marked: the step only moves on.
    var stepTalksNow: Bool {
        guard isStepped, !isReview, !isLocked else { return false }
        let marks = stepMarkPositions
        return message != nil || !marks.leaning.isEmpty || !marks.ruledOut.isEmpty
    }

    /// Pinned comments on the page also go now: the step does not move on past them (operator, 6 Nov).
    func stepTalksNow(comments: Int) -> Bool {
        stepTalksNow || (isStepped && !isReview && !isLocked && comments > 0)
    }

    /// The bottom bar's forward button: "Next", then "Review and send"; none on the review step.
    var nextLabel: String? {
        guard isStepped, !isReview else { return nil }
        return step + 1 < questions.count ? "Next" : "Review and send"
    }

    struct StepPill: Equatable {
        let index: Int
        /// A short title for a question; "Send" for the last pill.
        let title: String
        let isCurrent: Bool
        /// A question whose points are all answered.
        let isDone: Bool
        let isSend: Bool
        /// What the step bar shows (C2): the step number, or "Send".
        var number: String { isSend ? "Send" : "\(index + 1)" }
        /// The tooltip: the step's full title, and the group it belongs to; "Review and send" for the last pill.
        var help: String = ""
    }

    /// One pill per question and a last "Send" pill.
    var stepPills: [StepPill] {
        let done = progress
        var pills = questions.enumerated().map { index, question in
            StepPill(
                index: index, title: Self.shortTitle(question.title), isCurrent: step == index, isDone: done[index], isSend: false,
                help: Self.stepHelp(question, index: index))
        }
        pills.append(StepPill(
            index: questions.count, title: "Send", isCurrent: isReview, isDone: false, isSend: true, help: "Review and send"))
        return pills
    }

    /// "2. How do we show the options once?" and, on a second line, the group title (C2: the group label over
    /// the question moved here).
    static func stepHelp(_ question: Question, index: Int) -> String {
        let title = "\(index + 1). \(AgentMarkdown.singleLine(question.title))"
        guard let group = question.groupTitle.map(AgentMarkdown.singleLine), !group.isEmpty else { return title }
        return "\(title)\n\(group)"
    }

    /// The first words of a question title, for a pill.
    static func shortTitle(_ title: String, limit: Int = 18) -> String {
        let line = AgentMarkdown.singleLine(title)
        guard line.count > limit else { return line }
        let cut = line.prefix(limit)
        let trimmed = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        return trimmed.trimmingCharacters(in: .whitespaces) + "…"
    }

    struct ReviewRow: Equatable {
        let index: Int
        let title: String
        /// The choice of each answered point, in page order. Empty: "Not decided".
        let picks: [String]
        /// "Leaning: A", "Ruled out: B" (WAG-326): shown while nothing is picked.
        var marks: [String] = []
        var isDecided: Bool { !picks.isEmpty }
        var summary: String {
            if !picks.isEmpty { return picks.joined(separator: " · ") }
            return marks.isEmpty ? "Not decided" : marks.joined(separator: " · ")
        }
        /// A request with items needs every item answered, so the pill on an open row says so.
        var pendingWord = "Skip"
    }

    /// One row per question with its picks. A click on a row goes to that step.
    var reviewRows: [ReviewRow] {
        questions.enumerated().map { index, question in
            ReviewRow(
                index: index, title: AgentMarkdown.singleLine(question.title),
                picks: question.points.compactMap { pickText(question, $0) },
                marks: DiscussCopy.lines(
                    leaning: question.points.flatMap { draft(question.id, $0.id).leaning },
                    ruledOut: question.points.flatMap { draft(question.id, $0.id).ruledOut }),
                pendingWord: usesItems ? "Open" : "Skip")
        }
    }

    /// What the review step says about one point: the label picked, the labels ticked, or the written answer.
    private func pickText(_ question: Question, _ point: QuestionPoint) -> String? {
        let draft = draft(question.id, point.id)
        switch point.select {
        case .one: return draft.choice
        case .many: return draft.choices.isEmpty ? nil : draft.choices.joined(separator: ", ")
        case .reply:
            let text = AgentMarkdown.singleLine(draft.text)
            return text.isEmpty ? nil : text
        }
    }

    /// On the review step of a request with items: why Send may not send the answers yet.
    var reviewHint: String? {
        guard usesItems, isReview, !isLocked, answeredCount < totalPoints else { return nil }
        return "Make every decision to send your answers. Or write a note to keep talking."
    }

    // MARK: Progress

    var totalPoints: Int { questions.reduce(0) { $0 + $1.points.count } }

    func answeredCount(in question: Question) -> Int {
        question.points.filter { isAnswered(question: question, point: $0) }.count
    }

    var answeredCount: Int { questions.reduce(0) { $0 + answeredCount(in: $1) } }

    /// One bar per question, filled when all its points are decided.
    var progress: [Bool] { questions.map { answeredCount(in: $0) == $0.points.count } }

    // MARK: Variants

    /// The variant the question shows now: the picked one, else the first.
    func selectedVariant(for question: Question) -> String? {
        guard let list = question.variants, !list.isEmpty else { return nil }
        if let picked = variants[variantKey(question)], list.contains(where: { $0.id == picked }) { return picked }
        return list.first?.id
    }

    mutating func selectVariant(_ variant: String, question: String) {
        guard let step = questions.first(where: { $0.id == question }),
              step.variants?.contains(where: { $0.id == variant }) == true else { return }
        variants[variantKey(step)] = variant
    }

    /// A variant pick belongs to the group of a step (WAG-364), else to the step itself. A draft saved under the old
    /// group step id has the group id as its key, so it maps with no loss.
    private func variantKey(_ question: Question) -> String { question.groupId ?? question.id }

    /// The URL hash of the question's page: `plans` at first, `plans?variant=table` once a variant is picked.
    func fragment(for question: Question) -> String {
        let key = variantKey(question)
        guard let picked = variants[key], selectedVariant(for: question) == picked else { return key }
        return "\(key)?variant=\(picked)"
    }

    // MARK: Labels

    func sectionLabel(of question: Question) -> String {
        let index = (questions.firstIndex { $0.id == question.id } ?? 0) + 1
        return "QUESTION \(index) OF \(questions.count)"
    }

    static func toDecideLabel(_ question: Question) -> String { "DECIDE · \(question.points.count)" }

    static func nowLabel(_ lines: [String]) -> String { "How it works now · \(lines.count) point\(lines.count == 1 ? "" : "s")" }

    // MARK: Bottom bar

    var sendLabel: String { sendLabel(comments: 0) }

    /// "Send answers" / "Send 2 answers" / "Send feedback", then " + 3 comments" when comments are pinned.
    func sendLabel(comments: Int) -> String {
        var label: String
        if sendsAnswers {
            label = "Send \(answeredCount) answer\(answeredCount == 1 ? "" : "s")"
        } else if isDiscussing {
            label = PromptBarLogic.keepTalkingLabel
        } else {
            label = isFeedbackOnly || comments > 0 ? "Send feedback" : "Send answers"
        }
        // Comments alone are the whole feedback: the label does not count them again.
        if comments > 0, sendsAnswers || message != nil || isDiscussing { label += " + \(comments) comment\(comments == 1 ? "" : "s")" }
        return label
    }

    /// True when a send carries the answers as a Decide. A request with items needs every item answered
    /// (the daemon refuses a Decide that skips one); until then a send is a note to keep talking.
    var sendsAnswers: Bool { answeredCount > 0 && (!usesItems || answeredCount == totalPoints) }

    /// A note and no sendable answer: the person wants changes to the page before deciding (WAG-285).
    var isFeedbackOnly: Bool { !sendsAnswers && !isDiscussing && message != nil }

    var canSend: Bool { canSend(comments: 0) }

    /// Pinned comments alone are enough to send: the app sends `commentsOnlyMessage` with them (WAG-287).
    func canSend(comments: Int, hasFiles: Bool = false) -> Bool {
        !isLocked && (sendsAnswers || message != nil || comments > 0 || isDiscussing || hasFiles)
    }

    /// The message a send with only pinned comments carries, so the daemon's message rule holds.
    static let commentsOnlyMessage = "See my comments on the page."

    /// The message a send with only attached files carries (WAG-345), so the daemon always has one.
    static let filesOnlyMessage = "See my attached files."

    /// The answers in page order. A point you did not answer has none. Empty for a request with items: those
    /// go back as `itemAnswers()`.
    func answers() -> [PointAnswer] {
        guard !usesItems else { return [] }
        return questions.flatMap { question in
            question.points.compactMap { point -> PointAnswer? in
                let draft = draft(question.id, point.id)
                guard let choice = draft.choice else { return nil }
                let trimmed = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
                return PointAnswer(questionId: question.id, pointId: point.id, choice: choice, note: trimmed.isEmpty ? nil : trimmed)
            }
        }
    }

    /// The answers of a request with items, in page order, by item id. Each carries its option ids (or the
    /// written text) and the note. Empty for an older request.
    func itemAnswers() -> [ItemAnswer] {
        guard usesItems else { return [] }
        return questions.flatMap { question in
            question.points.compactMap { point -> ItemAnswer? in
                let draft = draft(question.id, point.id)
                guard isAnswered(draft, point), let itemId = point.itemId else { return nil }
                let trimmed = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
                let note = trimmed.isEmpty ? nil : trimmed
                switch point.select {
                case .one: return ItemAnswer(itemId: itemId, choice: draft.choice.map(point.optionId(forLabel:)), note: note)
                case .many: return ItemAnswer(itemId: itemId, choices: draft.choices.map(point.optionId(forLabel:)), note: note)
                case .reply: return ItemAnswer(itemId: itemId, text: draft.text.trimmingCharacters(in: .whitespacesAndNewlines), note: note)
                }
            }
        }
    }

    /// The free note, or `nil` when it is empty.
    var message: String? {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    mutating func markSent() {
        isLocked = true
        lockedOn = seen
        lockedUpdate = seenUpdate
    }

    // MARK: Evidence

    /// Evidence only (WAG-304): `KNOCK_EVIDENCE_STEP=<n>` opens on step n (1-based) and
    /// `KNOCK_EVIDENCE_PICKS=q.p=Choice;q.p=Choice` picks answers.
    mutating func applyEvidence(_ environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard !isLocked else { return }
        for pair in (environment["KNOCK_EVIDENCE_PICKS"] ?? "").split(separator: ";") {
            let halves = pair.split(separator: "=", maxSplits: 1).map(String.init)
            let ids = halves.first?.split(separator: ".").map(String.init) ?? []
            guard halves.count == 2, ids.count == 2 else { continue }
            choose(halves[1], question: ids[0], point: ids[1])
        }
        if let step = environment["KNOCK_EVIDENCE_STEP"].flatMap(Int.init) { jump(to: step - 1) }
    }

    // MARK: Hash of a page

    /// The question an artifact page opens at, from the fragment it was given.
    static func questionId(inFragment fragment: String) -> String {
        String(fragment.split(separator: "?", maxSplits: 1).first ?? "")
    }
}
