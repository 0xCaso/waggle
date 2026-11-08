import Foundation

/// One case's composer state (docs/design/mvp-values.md §M7 "Composer
/// states"): which option is currently selected (options cases only) and
/// whatever free text the human has typed. Owned per case, alongside
/// `CommentsSessionStore` (`ReviewWorkspaceView` creates one per case).
@MainActor
final class ComposerViewModel: ObservableObject {
    @Published var selectedOptionId: String?
    /// The ticked option ids of a select "many" ask (HAIL-123), in the order the options are shown.
    /// The recommended ones start ticked. Empty for a single-choice ask.
    @Published private(set) var selectedOptionIds: [String] = []
    /// True while `selectedOptionId` is an id of the ask's first option set
    /// (HAIL-108: picked under "First options" after an update). The send
    /// then names that set, since the newest set may reuse the same id.
    @Published var selectedFromFirstOptions = false
    /// The options the person leans to, and the ones they ruled out (WAG-301), in the order the options
    /// are shown. A row is in at most one list, and a pick clears both. Single-choice asks only.
    @Published private(set) var leaningIds: [String] = []
    @Published private(set) var ruledOutIds: [String] = []
    /// True while the pick is only the preselected recommendation of a plan round (WAG-303): the person has not
    /// touched a row yet, so the block reads RECOMMENDED, not YOUR PICK. Any tap, lean or rule out ends it.
    @Published private(set) var pickIsDefault = false
    /// The typed reply lives in its own object (HAIL-220), so a keystroke re-renders only the views
    /// that observe `draft` (the reply field), not the ask column that observes this model.
    let draft = ComposerDraftText()
    /// The files attached to the next reply (WAG-345). One object per case, shared with the other composer of the case.
    let files: ComposerAttachments
    /// True when a file is attached: it counts as something to send, and with no pick it keeps the talk going.
    var hasFiles: Bool { !files.isEmpty }
    var draftText: String {
        get { draft.text }
        set {
            guard newValue != draft.text else { return }
            draft.text = newValue
            persist()
        }
    }
    /// Set to focus the composer's message field the moment it next appears
    /// (docs/stories/HAIL-25.md): pressing "Open review" from the case pane,
    /// or picking an option whose label reads as a change request, should
    /// land the friend straight in the message field. Consumed once by
    /// `ComposerFooterView`, then reset to `false`.
    @Published var focusDraftOnOpen = false
    /// True while the "Ask for more detail" inline field is open (HAIL-33):
    /// swaps the normal Accept/Send row for the question field, its three
    /// chips, and the "Ask" primary action.
    @Published var isAskingForDetail = false
    /// The optional question typed (or picked via a chip) in the "Ask for
    /// more detail" field.
    @Published var detailQuestionText = ""

    /// The case as the pane last saw it. `refresh(_:)` replaces it when an
    /// update arrives (HAIL-108), so `options` always reads the newest set.
    @Published private(set) var knockCase: Case
    /// Non-nil for a case whose latest revision just arrived (docs/design/
    /// mvp-values.md §M9): swaps the accept button's label to "Confirm vN" -
    /// accepting here means confirming the returned revision, not choosing
    /// between options.
    private let revisionArrival: RevisionArrival?
    /// Shared across every `ComposerViewModel` built for the same case id
    /// (docs/stories/HAIL-25.md), so the case pane and the review workspace
    /// read and write the same selection and draft text. `nil` keeps a
    /// `ComposerViewModel` exactly as it behaved before this story - no
    /// restore, no persistence - which is what every call site that predates
    /// HAIL-25 (and every existing test) still does.
    private let draftStore: ComposerDraftStore?
    /// Where the composer's clicks are reported (HAIL-83). `nil` reports nothing.
    private let usage: UsageReporter?

    init(
        knockCase: Case, revisionArrival: RevisionArrival? = nil, draftStore: ComposerDraftStore? = nil,
        usage: UsageReporter? = nil, files: ComposerAttachments? = nil
    ) {
        self.files = files ?? draftStore?.files(caseId: knockCase.id) ?? ComposerAttachments()
        self.knockCase = knockCase
        self.revisionArrival = revisionArrival
        self.draftStore = draftStore
        self.usage = usage
        let restored = draftStore?.draft(caseId: knockCase.id)
        // No option starts selected (docs/stories/HAIL-36.md: the operator's
        // own reply once showed the recommendation as their chosen answer
        // even though they never clicked it - typing over the old default
        // silently carried it along). The recommended option still shows its
        // "Recommended" tag (`OptionChipView.isRecommended`, read straight
        // off `knockCase.recommendation`), but it is not selected until the
        // operator picks it - a restored draft's own selection (including a
        // restored `nil`) always wins.
        self.selectedOptionId = restored?.selectedOptionId
        self.selectedFromFirstOptions = restored?.selectedFromFirstOptions ?? false
        if let restored, restored.selectedOptionId == nil {
            self.leaningIds = Self.ordered(restored.leaningIds, in: knockCase.options)
            self.ruledOutIds = Self.ordered(restored.ruledOutIds, in: knockCase.options)
        }
        // Evidence only: `KNOCK_EVIDENCE_PICK_OPTION=<option id>` opens the ask with that option picked.
        if restored == nil, let id = ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_PICK_OPTION"],
           knockCase.options.contains(where: { $0.id == id }) { self.selectedOptionId = id }
        // Evidence only: `KNOCK_EVIDENCE_LEAN=a,b` and `KNOCK_EVIDENCE_RULE_OUT=c` open the ask with those option ids
        // leaning and ruled out (WAG-301).
        if restored == nil, !knockCase.options.isEmpty, knockCase.select != .many {
            let env = ProcessInfo.processInfo.environment
            let ids = { (key: String) in (env[key] ?? "").split(separator: ",").map(String.init) }
            if env["KNOCK_EVIDENCE_LEAN"] != nil || env["KNOCK_EVIDENCE_RULE_OUT"] != nil {
                self.leaningIds = Self.ordered(ids("KNOCK_EVIDENCE_LEAN"), in: knockCase.options)
                self.ruledOutIds = Self.ordered(ids("KNOCK_EVIDENCE_RULE_OUT"), in: knockCase.options)
                self.selectedOptionId = nil
            }
        }
        self.draft.text = restored?.draftText ?? ""
        // A plan round starts with its recommendation picked (HAIL-151), unless a restored draft
        // already holds a pick of its own.
        if restored == nil, !isDiscussing, Self.preselectsRecommendation(knockCase) {
            self.selectedOptionId = knockCase.recommendation
            self.pickIsDefault = true
        }
        // A select "many" ask opens with nothing ticked (WAG-329): the recommendation is a mark on its
        // rows, never the person's pick. A restored draft's own ticks win.
        if knockCase.select == .many, !knockCase.options.isEmpty {
            self.selectedOptionIds = restored.map { Self.ordered($0.selectedOptionIds ?? [], in: knockCase.options) } ?? []
            // Evidence only: `KNOCK_EVIDENCE_TICK=a,b` opens the ask with those options ticked.
            if restored == nil, let ticks = ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_TICK"] {
                self.selectedOptionIds = Self.ordered(ticks.split(separator: ",").map(String.init), in: knockCase.options)
            }
        }
    }

    // MARK: - Plan rounds (HAIL-151)

    /// No request pre-picks its recommendation, plan rounds and stages included (operator decision 9 Oct, WAG-336).
    /// The recommended row shows a soft mark; the button stays as with no pick until the person picks.
    static func preselectsRecommendation(_ item: Case) -> Bool { false }

    /// The stage of the plan round on screen; `nil` for any other ask.
    var planStage: PlanStageName? { knockCase.earlierRoundIsReadOnly ? nil : knockCase.plan?.stage.name }

    /// The primary button's words for this plan round ("Next question", "Approve section"...).
    var planPrimaryLabel: String? { planStage.map(PlanText.primaryLabel) }

    /// Its short words ("Approve"), used when the full label does not fit the row.
    var planShortPrimaryLabel: String? { planStage.map(PlanText.shortPrimaryLabel) }

    /// The second button of the design and spec rounds ("Change", "Request changes").
    /// Absent when the round already carries an option that means changes: one way to ask for them (WAG-336).
    var planSecondaryLabel: String? {
        PlanText.hasChangesOption(knockCase.options) ? nil : planStage.flatMap(PlanText.secondaryLabel)
    }

    // MARK: - Lean and rule out (WAG-301)

    /// True for a review: Approve and Request changes are its rows (WAG-316).
    var isReview: Bool { knockCase.kind == .review && isOptionsCase && !isMultiSelect }

    /// True when the options take lean and rule-out icons: a single-choice ask with options.
    var supportsDiscuss: Bool { isOptionsCase && !isMultiSelect }
    var isDiscussing: Bool { !leaningIds.isEmpty || !ruledOutIds.isEmpty }
    func isLeaning(_ id: String) -> Bool { leaningIds.contains(id) }
    func isRuledOut(_ id: String) -> Bool { ruledOutIds.contains(id) }

    /// The 1-based places of the leaning and ruled-out options, as the send button names them.
    var leaningPositions: [Int] { positions(of: leaningIds) }
    var ruledOutPositions: [Int] { positions(of: ruledOutIds) }
    private func positions(of ids: [String]) -> [Int] {
        knockCase.options.enumerated().filter { ids.contains($0.element.id) }.map { $0.offset + 1 }
    }

    /// True when pressing send is a question, not a decision: leans or rule-outs, or a note with no pick.
    var sendsDiscuss: Bool { supportsDiscuss && (isDiscussing || (!hasPick && (currentMessage != nil || hasFiles))) }

    /// The half circle: leans to this option, or takes the lean back. It clears the pick and the
    /// option's rule-out. Several rows can lean at once.
    func toggleLean(_ id: String) {
        guard supportsDiscuss, knockCase.options.contains(where: { $0.id == id }) else { return }
        let on = !leaningIds.contains(id)
        setDiscuss(id, lean: on, ruledOut: false)
    }

    /// The ×: rules this option out, or takes it back. It clears the pick and the option's lean.
    func toggleRuleOut(_ id: String) {
        guard supportsDiscuss, knockCase.options.contains(where: { $0.id == id }) else { return }
        let on = !ruledOutIds.contains(id)
        setDiscuss(id, lean: false, ruledOut: on)
    }

    private func setDiscuss(_ id: String, lean: Bool, ruledOut: Bool) {
        pickIsDefault = false
        leaningIds.removeAll { $0 == id }
        ruledOutIds.removeAll { $0 == id }
        if lean { leaningIds = Self.ordered(leaningIds + [id], in: knockCase.options) }
        if ruledOut { ruledOutIds = Self.ordered(ruledOutIds + [id], in: knockCase.options) }
        if lean || ruledOut {
            selectedOptionId = nil
            selectedFromFirstOptions = false
        }
        persist()
    }

    private func clearDiscuss() {
        leaningIds = []
        ruledOutIds = []
    }

    // MARK: - Pick several (HAIL-123)

    /// True while the current options take several picks.
    var isMultiSelect: Bool { knockCase.select == .many && !knockCase.options.isEmpty }
    /// The most options that may be ticked; `nil` for no limit.
    var maxChoices: Int? { isMultiSelect ? knockCase.max : nil }
    /// True once the ticks reach `max`: unticked rows dim and do not toggle.
    var isAtLimit: Bool { maxChoices.map { selectedOptionIds.count >= $0 } ?? false }
    func isTicked(_ id: String) -> Bool { selectedOptionIds.contains(id) }
    func canToggle(_ id: String) -> Bool { isTicked(id) || !isAtLimit }
    /// What the send button counts: ticked options, or 1 for a single pick.
    var pickCount: Int { isMultiSelect ? selectedOptionIds.count : (selectedOptionId == nil ? 0 : 1) }

    /// Ticks or unticks one option of the current set. A tick past the limit does nothing.
    func toggleOption(_ id: String, via source: OptionPickSource = .click) {
        guard isMultiSelect, knockCase.options.contains(where: { $0.id == id }) else { return }
        if selectedFromFirstOptions {
            selectedOptionId = nil
            selectedFromFirstOptions = false
        }
        if let index = selectedOptionIds.firstIndex(of: id) {
            selectedOptionIds.remove(at: index)
        } else {
            guard !isAtLimit else { return }
            selectedOptionIds = Self.ordered(selectedOptionIds + [id], in: knockCase.options)
            usage?.record(.optionPicked, source: source.rawValue)
        }
        persist()
    }

    /// The "Clear" link: unticks everything.
    func clearPicks() {
        guard !selectedOptionIds.isEmpty else { return }
        selectedOptionIds = []
        persist()
    }

    /// "Tick the recommended": one click ticks the recommended options, as the person's own ticks (WAG-329).
    func tickRecommended() {
        setPicks(Self.recommendedTicks(for: knockCase))
    }

    /// True when the recommended options are not all ticked yet, so "Tick the recommended" still has work to do.
    var canTickRecommended: Bool {
        let ids = Self.recommendedTicks(for: knockCase)
        return isMultiSelect && !ids.isEmpty && ids != selectedOptionIds
    }

    /// True for a pick-many ask with nothing ticked: a note or comments then keep the talk going (WAG-329).
    var talksOnMany: Bool { isMultiSelect && !hasPick }

    /// Replaces the ticks, as "Change answer" does with what was sent.
    func setPicks(_ ids: [String]) {
        selectedOptionIds = Self.ordered(ids, in: knockCase.options)
        persist()
    }

    /// The recommended ids that are options of the case, capped at `max`.
    static func recommendedTicks(for item: Case) -> [String] {
        let ids = ordered(item.recommendations, in: item.options)
        return item.max.map { Array(ids.prefix($0)) } ?? ids
    }

    private static func ordered(_ ids: [String], in options: [Option]) -> [String] {
        options.map(\.id).filter { ids.contains($0) }
    }

    /// The ids a send names for a select "many" ask: the ticks; with none ticked, an empty list
    /// when a note goes with it ("none of these"); otherwise `nil`, a plain reply with no choice
    /// (the daemon accepts an empty list only with a message).
    var currentChoices: [String]? {
        guard isMultiSelect, !selectedFromFirstOptions else { return nil }
        if !selectedOptionIds.isEmpty { return selectedOptionIds }
        return currentMessage != nil ? [] : nil
    }

    /// False once a message-only update settled the earlier round: only the reply field is left (WAG-337).
    var isOptionsCase: Bool { !knockCase.options.isEmpty && !knockCase.earlierRoundIsReadOnly }

    /// How the box frames the options (HAIL-108).
    var answerBox: AnswerBoxState { AnswerBoxState.make(for: knockCase) }

    /// The ask's own option set, shown under "First options" once an update came.
    var firstOptions: [Option] { knockCase.firstOptions }

    /// The case changed under an open composer (an update arrived): read the
    /// newest options, and drop a pick that no option offers any more.
    func refresh(_ updated: Case) {
        guard updated != knockCase else { return }
        let optionsChanged = updated.options != knockCase.options
        knockCase = updated
        if updated.select == .many, !updated.options.isEmpty {
            // A new set (an update with options) starts with nothing ticked (WAG-329); otherwise
            // only drop ticks that no option offers any more.
            selectedOptionIds = optionsChanged ? [] : Self.ordered(selectedOptionIds, in: updated.options)
            persist()
        } else if !selectedOptionIds.isEmpty {
            selectedOptionIds = []
            persist()
        }
        if optionsChanged {
            clearDiscuss()
        } else {
            leaningIds = Self.ordered(leaningIds, in: updated.options)
            ruledOutIds = Self.ordered(ruledOutIds, in: updated.options)
        }
        if let selectedOptionId {
            let pool = selectedFromFirstOptions ? updated.firstOptions : updated.options
            if !pool.contains(where: { $0.id == selectedOptionId }) {
                self.selectedOptionId = nil
                selectedFromFirstOptions = false
                persist()
            }
        }
        // A new plan round starts from its own recommendation.
        if optionsChanged, Self.preselectsRecommendation(updated) {
            selectedOptionId = updated.recommendation
            selectedFromFirstOptions = false
            pickIsDefault = true
            persist()
        }
    }

    /// The case's options, in display order (HAIL-54): the numbered-badge
    /// composer card needs this list directly - the pane's `PaneOptionsList`
    /// used to read `item.options` off the `Case` it already held separately,
    /// but the shared `ComposerCardView` only holds this view model.
    var options: [Option] { knockCase.options }

    /// The selected option's 1-indexed position in `options` (HAIL-54): the
    /// numbered badge and the "Send <n>" button label both name an option by
    /// its position, not its id or label text. `nil` with no selection, for a
    /// free-text case, or (defensively) for a selected id `options` no longer
    /// carries.
    var selectedOptionPosition: Int? {
        guard isOptionsCase, let selectedOptionId else { return nil }
        return knockCase.options.firstIndex(where: { $0.id == selectedOptionId }).map { $0 + 1 }
    }

    /// Picks the option at a 1-indexed position (HAIL-54: pressing "1", "2",
    /// … picks that row, the same toggle `selectOption(_:)` already gives a
    /// click - HAIL-43's deselect-on-repeat still applies). A position past
    /// the option count - e.g. "4" pressed on a 3-option case - is a no-op,
    /// the same as `ComposerKeyMapping.optionIndex` returning `nil` for it.
    func selectOption(atPosition position: Int) {
        guard let index = ComposerKeyMapping.optionIndex(forDigit: position, optionCount: knockCase.options.count) else { return }
        selectOption(knockCase.options[index].id, via: .numberKey)
    }

    /// "Accept recommendation" (options) / "Send recommended answer" (free
    /// text) - docs/design/mvp-values.md §M7 panels A and B. "Confirm vN"
    /// (§M9 `ZBEXl`) takes priority over both once a revision has arrived.
    var acceptButtonLabel: String {
        if let revisionArrival { return "Confirm v\(revisionArrival.latestRevision)" }
        return isOptionsCase ? "Accept recommendation" : "Send recommended answer"
    }

    /// Clicking the already-selected option again clears it (docs/stories/
    /// HAIL-43.md, operator via Knock 2026-09-28: "What if i don't want to
    /// pick any, and just send a comment? Can i deselect either A or B after
    /// selecting one?") - the only way back to "no option" once one has been
    /// picked, short of reloading the case.
    func selectOption(_ id: String, via source: OptionPickSource = .click) {
        if isMultiSelect {
            toggleOption(id, via: source)
            return
        }
        let clearing = selectedOptionId == id && !selectedFromFirstOptions
        pickIsDefault = false
        selectedOptionId = clearing ? nil : id
        selectedFromFirstOptions = false
        // A pick clears every lean and rule-out (WAG-301).
        if !clearing { clearDiscuss() }
        persist()
        // Picking counts; clearing the pick does not (HAIL-83).
        if selectedOptionId != nil { usage?.record(.optionPicked, source: source.rawValue) }
    }

    /// Picks (or clears) an option of the first set (HAIL-108), shown dimmed
    /// under "First options". Keys 1..N never reach these rows.
    func selectFirstOption(_ id: String) {
        let clearing = selectedOptionId == id && selectedFromFirstOptions
        pickIsDefault = false
        selectedOptionId = clearing ? nil : id
        selectedFromFirstOptions = !clearing
        if !clearing { clearDiscuss() }
        // A pick under "First options" is a single choice: it replaces any ticks (HAIL-123).
        if !clearing { selectedOptionIds = [] }
        persist()
        if !clearing { usage?.record(.optionPicked, source: OptionPickSource.click.rawValue) }
    }

    /// "first" when the pick is from the first set, else `nil` (the newest).
    var currentOptionsSet: String? { isOptionsCase && selectedOptionId != nil && selectedFromFirstOptions ? "first" : nil }

    /// The person typed in the reply field. Recorded once per ask (HAIL-83),
    /// on the first keystroke; text set by the app never reaches here.
    func replyEdited() {
        usage?.recordOnce(.replyTyped, caseId: knockCase.id)
    }

    /// Empties the composer and its shared draft (HAIL-74): after a reply is
    /// sent, or when a new round starts, the field, selection and detail
    /// question all start blank.
    func reset() {
        selectedOptionId = nil
        selectedFromFirstOptions = false
        selectedOptionIds = []
        clearDiscuss()
        pickIsDefault = false
        if Self.preselectsRecommendation(knockCase) {
            selectedOptionId = knockCase.recommendation
            pickIsDefault = true
        }
        draftText = ""
        isAskingForDetail = false
        detailQuestionText = ""
        // The daemon already removed the copies of a sent reply; for a cancelled draft this removes them.
        files.clear()
        draftStore?.clear(caseId: knockCase.id)
    }

    private func persist() {
        guard let draftStore else { return }
        draftStore.save(
            caseId: knockCase.id, selectedOptionId: selectedOptionId, draftText: draftText,
            selectedFromFirstOptions: selectedFromFirstOptions,
            selectedOptionIds: isMultiSelect ? selectedOptionIds : nil,
            leaningIds: leaningIds, ruledOutIds: ruledOutIds)
    }

    /// The composer's own Send action: the selected option (options cases
    /// only - a free-text case has nothing to choose) plus whatever is
    /// typed.
    var currentChoice: String? {
        guard isOptionsCase else { return nil }
        // A select "many" ask sends `currentChoices`; only a pick under "First options" is a choice.
        if isMultiSelect { return selectedFromFirstOptions ? selectedOptionId : nil }
        // A plan round's preselected recommendation is a suggestion, not a choice (WAG-328).
        if pickIsDefault { return nil }
        return selectedOptionId
    }

    /// True while the only pick is a plan round's preselected recommendation (WAG-328).
    var hasPrePick: Bool { isOptionsCase && pickIsDefault && selectedOptionId != nil }

    /// One option chosen (not a pre-pick) and non-blank text: the button reads "Approve with changes" or
    /// "Decide with changes" (WAG-353). `nil` for a request-changes pick, a lean, no pick or many ticks.
    var withChangesKind: WithChanges.Kind? {
        guard isOptionsCase, !isMultiSelect, !isDiscussing, currentMessage != nil, let id = currentChoice else { return nil }
        let pool = selectedFromFirstOptions ? firstOptions : options
        guard let option = pool.first(where: { $0.id == id }) else { return nil }
        return WithChanges.kind(of: option, planStage: planStage)
    }

    /// True when the bar holds nothing but the pre-pick: no note, no comments, no edit. Its button then
    /// reads "Decide: <option>", and pressing that button is the person's act (WAG-328).
    func isPrePickOnly(commentCount: Int, hasEdit: Bool = false) -> Bool {
        hasPrePick && currentMessage == nil && commentCount == 0 && !hasEdit
    }

    /// The person pressed the button that names the pre-pick: it is now their pick.
    func confirmPrePick() {
        guard pickIsDefault else { return }
        pickIsDefault = false
        persist()
    }

    /// True when there is a pick to send: a chosen option, or at least one tick.
    var hasPick: Bool { currentChoice != nil || !selectedOptionIds.isEmpty }

    /// The currently selected option's own label (docs/stories/HAIL-43.md):
    /// drives `ComposerFooterView.sendLabel` once a comment is pinned, so
    /// the send button reads "Send <label>" while an option is picked and
    /// falls back to a plain "Send reply" the moment it is cleared. `nil`
    /// for a free-text case (nothing to choose) and once no option is
    /// selected.
    var selectedOptionLabel: String? {
        guard isOptionsCase, let selectedOptionId else { return nil }
        let pool = selectedFromFirstOptions ? knockCase.firstOptions : knockCase.options
        return pool.first(where: { $0.id == selectedOptionId })?.label ?? selectedOptionId
    }

    var currentMessage: String? {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// "Accept recommendation ⌘D" / "Send recommended answer ⌘D": the
    /// recommendation itself, independent of whatever is typed in the free
    /// text field (docs/design/mvp-values.md §M7: a distinct action from the
    /// composer's own Send).
    var recommendationChoice: String? {
        // A review with a free-text recommendation has no row to accept (WAG-316, Q2).
        isOptionsCase && !isMultiSelect && !knockCase.recommendation.isEmpty ? knockCase.recommendation : nil
    }
    /// ⌘D on a select "many" ask sends the recommended list.
    var recommendationChoices: [String]? { isMultiSelect ? Self.recommendedTicks(for: knockCase) : nil }
    var recommendationMessage: String? { knockCase.options.isEmpty ? knockCase.recommendation : nil }

    /// The footer's primary action (Amendments, HAIL-25 continue pass): a
    /// pick that differs from the recommendation had no visible way to send
    /// it - "Accept recommendation" would send the recommendation instead.
    /// A typed note over an unchanged pick has the same problem the other
    /// way: "Accept recommendation" sends the pick alone and drops the note.
    enum FooterPrimaryAction: Equatable {
        case acceptRecommendation
        case sendOption(position: Int)
        /// Several ticks go out together (HAIL-123): "Send 2".
        case sendPicks(count: Int)
        case send
    }

    var footerPrimaryAction: FooterPrimaryAction {
        // Leans and rule-outs are sent as they are, never swapped for the recommendation (WAG-301).
        if isDiscussing { return .send }
        // A review decides only with a row picked. Comments or a note with no row keep the talk going (WAG-316, Q3).
        if isReview, !hasPick { return .send }
        if isMultiSelect, !selectedFromFirstOptions {
            return selectedOptionIds.isEmpty ? .send : .sendPicks(count: selectedOptionIds.count)
        }
        // A pick under "First options" has no number key: it sends as a plain "Send".
        if isOptionsCase, selectedOptionId != nil, selectedFromFirstOptions { return .send }
        if isOptionsCase, let selectedOptionId, selectedOptionId != knockCase.recommendation {
            let position = knockCase.options.firstIndex(where: { $0.id == selectedOptionId }).map { $0 + 1 } ?? 0
            return .sendOption(position: position)
        }
        if currentMessage != nil || hasFiles {
            return .send
        }
        return .acceptRecommendation
    }

    /// The primary button's own label (HAIL-54 Pen V1+V3: "Send <n> ⌘↵" /
    /// "Send ⌘↵" / "Accept recommendation ⌘D"), plus the "+ N comments" suffix
    /// once comments are pinned - a pure function of `footerPrimaryAction` and
    /// `commentCount` so the three states and the suffix are each unit-
    /// testable without hosting `ComposerCardView`/`ComposerFooterView`.
    /// `compact` is the narrow-column form (the review workspace): "Accept"
    /// instead of "Accept recommendation", so the toolbar stays on one row.
    static func primaryButtonLabel(action: FooterPrimaryAction, commentCount: Int, compact: Bool = false) -> String {
        let base: String
        switch action {
        case .acceptRecommendation: base = compact ? "Accept" : "Accept recommendation"
        case .sendOption(let position): base = "Send \(position)"
        case .sendPicks(let count): base = "Send \(count)"
        case .send: base = "Send"
        }
        guard commentCount > 0 else { return base }
        return "\(base) + \(commentCount) comment\(commentCount == 1 ? "" : "s")"
    }

    /// The primary button's key hint: "⌘D" only for `.acceptRecommendation`,
    /// "⌘↵" otherwise - both shortcuts stay wired regardless of which one is
    /// showing (⌘D always accepts the recommendation, ⌘↵ always sends).
    static func primaryButtonKeyHint(action: FooterPrimaryAction) -> String {
        if case .acceptRecommendation = action { return "⌘D" }
        return "⌘↵"
    }

    // MARK: - Ask for more detail (HAIL-33)

    /// The quick asks of the detail panel (HAIL-111): one tap or key sends the text as the detail request.
    static let detailChips = [howItWorksAsk, "Explain the trade-offs", "Show me a prototype", "Show the numbers", "Give me an example"]
    /// The "how it works" request (WAG-384): the first quick ask, the same text from the row and the panel.
    static let howItWorksAsk = "Explain how the code behind this decision works."
    /// The usage log's word for each quick ask, in the same order (WAG-366).
    static let detailChipUsageNames = ["how_it_works", "tradeoffs", "prototype", "numbers", "example"]

    /// `fromDots` marks the three dots pill of the "Ask for" row (WAG-367) in the usage log.
    func beginAskingForDetail(fromDots: Bool = false) {
        usage?.record(UsageRecord(.askMoreDetailOpened, source: fromDots ? "button" : nil))
        detailQuestionText = ""
        isAskingForDetail = true
    }

    func cancelAskingForDetail() {
        isAskingForDetail = false
        detailQuestionText = ""
    }

    func fillDetailChip(_ text: String) {
        detailQuestionText = text
    }

    /// The trimmed question, or `nil` when the field is empty (the AC marks
    /// it optional).
    var detailQuestion: String? {
        let trimmed = detailQuestionText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The typed reply, published on its own (HAIL-220). Only the reply field's views observe it.
@MainActor
final class ComposerDraftText: ObservableObject {
    @Published var text = ""
}

/// Whether the composer's own placeholder overlay should show
/// (docs/stories/HAIL-34.md operator report 21:13: the field showed no
/// placeholder text at all, empty with just a cursor). A pure function of
/// the draft text, unit-testable without hosting `ComposerFooterView`.
enum ComposerPlaceholder {
    static func isVisible(draftText: String) -> Bool { draftText.isEmpty }
}

extension Option {
    /// A heuristic for "an option whose label signals a change request"
    /// (docs/stories/HAIL-25.md): a catch-all label like "Something else" or
    /// "Change the copy" should route straight to the review's message
    /// field rather than a plain accept. See the Choices ledger.
    var signalsChangeRequest: Bool {
        let needle = label.lowercased()
        return ["change", "something else", "other", "custom", "different", "edit", "rewrite", "modify"]
            .contains { needle.contains($0) }
    }
}
