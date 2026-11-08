import Foundation

/// One (`selectedOptionId`, `draftText`) draft per case id, kept in memory
/// for as long as the app runs (docs/stories/HAIL-25.md: "the pane and the
/// review share one draft per case"). `ComposerViewModel` restores from this
/// store at init and writes back on every change, so a selection made in the
/// case pane survives into "Open review", and a draft typed in the review
/// workspace survives back into the pane - without either side needing to
/// hold the same `ComposerViewModel` instance.
@MainActor
final class ComposerDraftStore {
    static let shared = ComposerDraftStore()

    struct Draft {
        var selectedOptionId: String?
        var draftText: String
        var selectedFromFirstOptions = false
        /// The ticked ids of a select "many" ask (HAIL-123). `nil` in a draft saved before this
        /// existed; `[]` is a deliberate "nothing ticked".
        var selectedOptionIds: [String]? = nil
        /// The leans and rule-outs of a single-choice ask (WAG-301).
        var leaningIds: [String] = []
        var ruledOutIds: [String] = []
    }

    private var drafts: [String: Draft] = [:]
    /// The files attached to each case's next reply (WAG-345), shared like the draft text.
    private var attached: [String: ComposerAttachments] = [:]
    private let makeFiles: @MainActor () -> ComposerAttachments

    init(makeFiles: @escaping @MainActor () -> ComposerAttachments = { ComposerAttachments() }) {
        self.makeFiles = makeFiles
    }

    /// The case's attached files; the same object for the pane and the review workspace.
    func files(caseId: String) -> ComposerAttachments {
        if let existing = attached[caseId] { return existing }
        let created = makeFiles()
        attached[caseId] = created
        return created
    }

    func draft(caseId: String) -> Draft? { drafts[caseId] }

    func save(
        caseId: String, selectedOptionId: String?, draftText: String, selectedFromFirstOptions: Bool = false,
        selectedOptionIds: [String]? = nil, leaningIds: [String] = [], ruledOutIds: [String] = []
    ) {
        drafts[caseId] = Draft(
            selectedOptionId: selectedOptionId, draftText: draftText,
            selectedFromFirstOptions: selectedFromFirstOptions, selectedOptionIds: selectedOptionIds,
            leaningIds: leaningIds, ruledOutIds: ruledOutIds)
    }

    /// Drops a case's draft once its reply is sent, or a new round starts
    /// (HAIL-74): the next composer for the case opens empty.
    func clear(caseId: String) {
        drafts[caseId] = nil
        attached[caseId]?.clear()
    }
}
