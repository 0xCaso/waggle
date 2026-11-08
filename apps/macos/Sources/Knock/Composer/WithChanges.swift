import Foundation

/// "Approve with changes" (WAG-353): one chosen option plus text. Pure, so the words are unit-tested.
enum WithChanges {
    enum Kind: Equatable {
        /// The chosen option is an approval (the review's Approve, a plan section approve).
        case approve
        /// Any other chosen option.
        case decide
    }

    static let approveLabel = "Approve with changes"
    static let decideLabel = "Decide with changes"

    /// The kind for a chosen option; `nil` for a "request changes" pick, which keeps its own meaning.
    static func kind(of option: Option, planStage: PlanStageName? = nil) -> Kind? {
        if option.id == ReviewRows.changesId || PlanText.hasChangesOption([option]) { return nil }
        let title = AgentMarkdown.singleLine(option.displayTitle).lowercased()
        if option.id == ReviewRows.approveId || title.hasPrefix("approve") { return .approve }
        if planStage == .design || planStage == .spec { return .approve }
        return .decide
    }

    /// The send button's words, longest first: with the comments count, without it, then the short word.
    static func buttonLabels(_ kind: Kind, commentCount: Int) -> [String?] {
        let full = kind == .approve ? approveLabel : decideLabel
        let short = kind == .approve ? "Approve" : PromptBarLogic.decideLabel
        var forms: [String?] = []
        let withComments = commentCount > 0 ? "\(full) + \(commentCount) comment\(commentCount == 1 ? "" : "s")" : full
        for form in [withComments, full, short] where !forms.contains(form) { forms.append(form) }
        return forms
    }

    /// The answered state's words: "Approved with changes" or "<option title>, with changes".
    static func answeredWords(_ kind: Kind, title: String) -> String {
        kind == .approve ? "Approved with changes" : "\(title), with changes"
    }
}

extension Case {
    /// The kind of the latest reply when it is a single choice with non-blank text; `nil` otherwise.
    var latestReplyWithChanges: WithChanges.Kind? {
        guard latestReplyIntent == .decision, latestReplyChoices.isEmpty, let choice = latestReplyChoice,
              !(latestReplyMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let option = repliedOptions.first(where: { $0.id == choice }) else { return nil }
        return WithChanges.kind(of: option, planStage: plan?.stage.name)
    }

    /// The latest single choice in plain words when it carries changes, else `nil`.
    var latestReplyWithChangesWords: String? {
        guard let kind = latestReplyWithChanges, let choice = latestReplyChoice,
              let option = repliedOptions.first(where: { $0.id == choice }) else { return nil }
        return WithChanges.answeredWords(kind, title: option.displayTitle)
    }
}
