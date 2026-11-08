import SwiftUI

/// The grey line above the ask title: where the ask comes from, in one line. It replaces the old boxed
/// Context card.
enum AskCrumbs {
    /// "Gym OS / Share link settings": the project and the session title. The folder or worktree name
    /// ("shaded-town-51fbc404") shows only in a tooltip (`folderHelp`), never in the line (WAG-290).
    /// With no session title the line is the project alone.
    static func breadcrumb(task: KnockTask, sessionTitle: String?, separator: String = " / ") -> String {
        let project = projectName(task)
        guard let rest = titlePart(task: task, sessionTitle: sessionTitle) else { return project }
        return "\(project)\(separator)\(rest)"
    }

    /// The project in plain words (WAG-302): a worktree-like project ("fragrant-hospital-fc8f1973") reads
    /// "Fragrant hospital". A topic with spaces ("Gym OS") shows as written.
    static func projectName(_ task: KnockTask) -> String {
        let plain = ProjectName.display(project: task.project)
        return plain.isEmpty ? task.project : plain
    }

    /// The part after the project: the session title, or nothing. A task name is an internal slug
    /// ("brainstorm", "app"), so it never shows in the line (WAG-324). The ask title sits right below.
    static func titlePart(task: KnockTask, sessionTitle: String?) -> String? {
        guard let sessionTitle, !sessionTitle.isEmpty else { return nil }
        return sessionTitle
    }

    /// The folder name for the tooltip, when it is not the project name.
    static func folderHelp(_ task: KnockTask) -> String { task.name == task.project ? task.project : task.name }

    /// "Gym OS / app · Claude Code · 3rd ask in this session".
    static func line(breadcrumb: String, runtime: String, askNumber: Int?, step: String? = nil) -> String {
        var parts = [breadcrumb, runtime]
        if let askNumber, askNumber > 1 { parts.append("\(SessionContextBlock.ordinal(askNumber)) decision in this session") }
        if let step { parts.append(step) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

extension AskCrumbs {
    /// The one crumb of every screen (WAG-333): the case page and the full size column build it here.
    /// A stepped ask drops the ask number and names the step instead.
    static func screenLine(
        task: KnockTask, sessionTitle: String?, runtime: String, askNumber: Int?, doc: QuestionsDocModel?
    ) -> String {
        let stepped = doc?.isStepped == true
        return line(
            breadcrumb: breadcrumb(task: task, sessionTitle: sessionTitle), runtime: runtime,
            askNumber: stepped ? nil : askNumber, step: stepped ? doc?.stepCrumb : nil)
    }

    /// The case title shows once per screen (WAG-333). A stepped ask shows each question as the title.
    static func showsCaseTitle(doc: QuestionsDocModel?) -> Bool { doc?.isStepped != true }
}

/// "WHAT I NEED FROM YOU" on honey soft, and "Why you" under it in grey (Pen Round 2).
struct NeedCalloutView: View {
    let need: String
    let why: String?
    /// The small caps line over the text; a plan question says which question it is (WAG-276).
    var label = "WHAT I NEED FROM YOU"
    /// The narrow review panel: a smaller need text and tighter padding.
    var isCompact = false
    /// What the label or the stage track above the box already says ("Design · section 3 of 3"). A leading
    /// "Section 3 of 3:" in the need that says the same is dropped (WAG-294).
    var labelAbove: String?
    @Environment(\.sourcesHub) private var sourcesHub

    var body: some View {
        // WAG-359: a source no text cites shows as a pill at the end of the why text, else of the need.
        let uncited = sourcesHub?.book.uncited ?? []
        let whyHasText = why.map { !$0.isEmpty } ?? false
        let need = whyHasText ? need : SourceMarkers.appending(uncited: uncited, to: need)
        VStack(alignment: .leading, spacing: 10) {
            // An empty need (it repeated the title) leaves out the box; "Why you" stays.
            if !need.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .knockTextStyle(Theme.AskDoc.Typography.monoLabel10_5)
                    .foregroundColor(Theme.AskDoc.Colors.needLabel)
                let parts = NeedText.split(need, labelAbove: labelAbove ?? label)
                let base = isCompact ? Theme.Typography.body13_5w400 : Theme.AskDoc.Typography.need17
                VStack(alignment: .leading, spacing: 10) {
                    if !parts.question.isEmpty {
                        AgentMarkdownText(
                            text: parts.question, style: NeedText.questionStyle(base), color: Theme.Colors.ink, showsSources: true,
                            target: AskCommentTarget(.need, slot: "question"), weight: .semibold)
                    }
                    if let details = parts.details {
                        // The details start after the question in the plain text of the need.
                        let base = parts.question.isEmpty ? 0 : AskTextContent.plainLength(of: parts.question, mode: .blocks) + 1
                        AgentMarkdownText(
                            text: details, style: NeedText.detailStyle(isCompact ? Theme.Typography.body13_5w400 : Theme.AskDoc.Typography.need17),
                            color: Theme.Colors.ink2, showsSources: true,
                            target: AskCommentTarget(.need, slot: "details", baseOffset: base))
                    }
                }
                .textSelection(.enabled)
            }
            .padding(isCompact
                ? EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
                : EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.honeySoft)
            .clipShape(RoundedRectangle(cornerRadius: Theme.AskDoc.Radius.need))
            }
            if let why, !why.isEmpty {
                SourcedText(
                    text: SourceMarkers.appending(uncited: uncited, to: why), prefix: "Why you:", style: Theme.AskDoc.Typography.why13_5, color: Theme.Colors.ink3,
                    target: AskCommentTarget(.why))
                    .textSelection(.enabled)
            }
        }
    }
}

/// The need box reads as a question plus details (WAG-294): the first paragraph is the question in
/// semibold ink, the other paragraphs and lists are details in ink2 regular, a little smaller.
enum NeedText {
    struct Parts: Equatable {
        var question: String
        var details: String?
    }

    /// Splits at the first blank line. A text that opens with a list has no question. A leading
    /// "Section n of N:" or "Question n of N:" goes when `labelAbove` already says it.
    static func split(_ need: String, labelAbove: String? = nil) -> Parts {
        let text = dropSectionPrefix(need.trimmingCharacters(in: .whitespacesAndNewlines), labelAbove: labelAbove)
        let paragraphs = RoundHeading.paragraphs(text)
        guard let first = paragraphs.first else { return Parts(question: "", details: nil) }
        let opensWithList = first.components(separatedBy: "\n").first.map {
            AgentMarkdown.listMarker($0.trimmingCharacters(in: .whitespaces)) != nil
        } ?? false
        if opensWithList { return Parts(question: "", details: text) }
        let rest = paragraphs.dropFirst().joined(separator: "\n\n")
        return Parts(question: first, details: rest.isEmpty ? nil : rest)
    }

    /// True when `need` says no more than `title`: the same words, whatever the markers, case or final dot.
    static func repeats(_ need: String, title: String) -> Bool {
        let a = normalized(need), b = normalized(title)
        return !a.isEmpty && a == b
    }

    private static func normalized(_ text: String) -> String {
        AgentMarkdown.singleLine(text).lowercased()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static let prefix = try! NSRegularExpression(
        pattern: #"^(\*\*)?((?:Section|Question) \d+ of ~?\d+)\s*[:.\-\u2013\u2014]\s*(\*\*)?\s*"#,
        options: [.caseInsensitive])

    static func dropSectionPrefix(_ text: String, labelAbove: String?) -> String {
        guard let labelAbove, !labelAbove.isEmpty else { return text }
        let ns = text as NSString
        guard let m = prefix.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
            labelAbove.lowercased().contains(ns.substring(with: m.range(at: 2)).lowercased())
        else { return text }
        var rest = ns.substring(from: m.range.upperBound)
        // "**Section 3 of 3: Today**": keep the bold that still has its closing marker.
        if m.range(at: 1).location != NSNotFound, m.range(at: 3).location == NSNotFound { rest = "**" + rest }
        return rest.isEmpty ? text : rest
    }

    static func questionStyle(_ base: Theme.TextStyle) -> Theme.TextStyle {
        Theme.TextStyle(font: base.font.weight(.semibold), size: base.size, lineHeight: base.lineHeight, letterSpacing: base.letterSpacing)
    }

    /// One point smaller than the question, regular weight.
    static func detailStyle(_ base: Theme.TextStyle) -> Theme.TextStyle {
        let size = max(base.size - 2, 12)
        return Theme.TextStyle(
            font: .custom(Theme.FontFamily.sans, size: size), size: size, lineHeight: base.lineHeight, letterSpacing: base.letterSpacing)
    }
}

/// How wide the column that holds an ask header is (WAG-302). The title size follows this class, never
/// the screen: the same column gets the same size in the pane and in the workspace.
enum AskHeaderWidth: Equatable {
    /// The full pane page. Waggle title scale: 28/600.
    case wide
    /// A side column: the workspace column or the 40% plan column. 19/650.
    case narrow

    var titleStyle: Theme.TextStyle {
        switch self {
        case .wide: Theme.AskDoc.Typography.askTitle28
        case .narrow: Theme.Typography.dialogTitle19w650
        }
    }
}

/// The grey crumb line over an ask title, with the menu of earlier asks beside it. One view for the
/// case pane page and the workspace column (WAG-302). `crumb` is nil in the workspace, where the
/// titlebar already shows it.
struct AskCrumbLine: View {
    var crumb: String?
    var help: String? = nil
    var earlierAsks: EarlierAsksModel?
    var onOpenCase: (String) -> Void
    var onOpenHistory: (() -> Void)?

    var body: some View {
        if crumb != nil || earlierAsks?.linkLabel != nil {
            HStack(spacing: 6) {
                if let crumb {
                    Text(crumb)
                        .knockTextStyle(Theme.AskDoc.Typography.crumbs12)
                        .foregroundColor(Theme.AskDoc.Colors.quiet)
                        .lineLimit(1).truncationMode(.tail)
                        .help(help ?? "")
                }
                if let earlierAsks {
                    EarlierAsksLink(model: earlierAsks, onOpenCase: onOpenCase, onOpenHistory: onOpenHistory)
                        .layoutPriority(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The ask title: the round heading when the ask is in a later round, else the title with its
/// description. The size follows the column width class.
struct AskTitleView: View {
    let heading: RoundHeading?
    let title: String
    let width: AskHeaderWidth

    var body: some View {
        if let heading {
            RoundHeadingView(heading: heading, titleStyle: width.titleStyle)
        } else {
            let split = TitleSplit.make(title)
            VStack(alignment: .leading, spacing: 6) {
                TitleText(text: split.title, style: width.titleStyle)
                if let description = split.description {
                    TitleDescriptionView(text: description)
                }
            }
        }
    }
}

/// The title text of an ask. The person can comment on its words (WAG-357); outside a request page it is plain text.
struct TitleText: View {
    let text: String
    let style: Theme.TextStyle
    @Environment(\.askComments) private var askHub

    var body: some View {
        if askHub != nil {
            SourcedText(text: text, style: style, color: Theme.Colors.ink, target: AskCommentTarget(.title), weight: .semibold)
        } else {
            Text(text)
                .knockTextStyle(style)
                .foregroundColor(Theme.Colors.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
