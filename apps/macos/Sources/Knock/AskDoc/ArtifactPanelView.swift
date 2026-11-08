import SwiftUI

/// Header of an opened artifact, shared by the side panel and the full page.
private struct ArtifactHeaderBar<Leading: View>: View {
    let card: ArtifactCardModel
    let subtitle: String?
    let leading: Leading
    let onReset: () -> Void
    /// WAG-280: the case's comments, listed in a popover from the header; `nil` for an artifact with no pins.
    let commentsStore: CommentsSessionStore?
    /// WAG-307: the viewer behind the popover's list, so a comment whose page state is gone lands under "On other views".
    var viewer: ReviewViewModel? = nil
    let onClose: (() -> Void)?

    @State private var showsComments = false

    var body: some View {
        HStack(spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Image(systemName: card.type.symbol).font(.system(size: 11)).foregroundColor(Theme.Colors.ink2)
                    Text(card.kindLine)
                        .knockTextStyle(Theme.AskDoc.Typography.monoLabel10_5)
                        .foregroundColor(Theme.Colors.ink3)
                }
                Text(card.name)
                    .knockTextStyle(Theme.AskDoc.Typography.artifactName15)
                    .foregroundColor(Theme.Colors.ink)
                if let subtitle {
                    Text(subtitle)
                        .knockTextStyle(Theme.Typography.caption11_5w400)
                        .foregroundColor(Theme.Colors.ink3)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            if card.type == .prototype { miniButton("Reset", symbol: "arrow.clockwise", action: onReset) }
            if let commentsStore { commentsButton(commentsStore) }
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.Colors.ink2)
                        .frame(width: 28, height: 28)
                        .background(Theme.Colors.side)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                .accessibilityLabel("Close")
                .help("Close (Esc)")
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .overlay(Rectangle().fill(Theme.Colors.line).frame(height: 1), alignment: .bottom)
    }

    private func commentsButton(_ store: CommentsSessionStore) -> some View {
        CommentsCountButton(store: store, viewer: viewer, showsComments: $showsComments) {
            miniButton(Self.commentsLabel(store.model.comments.count), symbol: "text.bubble") { showsComments.toggle() }
        }
    }

    static func commentsLabel(_ count: Int) -> String {
        count == 0 ? "Comments" : (count == 1 ? "1 comment" : "\(count) comments")
    }

    private func miniButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(label).knockTextStyle(Theme.AskDoc.Typography.chip12_5)
            }
            .foregroundColor(Theme.Colors.ink2)
            .padding(EdgeInsets(top: 3, leading: 9, bottom: 3, trailing: 9))
            .background(Theme.Colors.win)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.Colors.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
    }
}

/// Holds the comments popover of an artifact header and redraws it when the case's comments change.
private struct CommentsCountButton<Label: View>: View {
    @ObservedObject var store: CommentsSessionStore
    var viewer: ReviewViewModel? = nil
    @Binding var showsComments: Bool
    @ViewBuilder let label: () -> Label

    var body: some View {
        label().popover(isPresented: $showsComments, arrowEdge: .bottom) {
            CaseCommentsListView(
                store: store, context: viewer?.commentViewContext ?? .unknown,
                onShow: { viewer?.showComment($0) })
        }
    }
}

/// The variant chips of a question, shown once, in the side panel (prototype `.vs`).
struct VariantChipsView: View {
    let question: Question
    let selectedId: String?
    let onSelect: (String) -> Void

    var body: some View {
        if let variants = question.variants, variants.count > 1 {
            HStack(spacing: 6) {
                if let label = question.variantLabel {
                    Text(label.uppercased())
                        .knockTextStyle(Theme.AskDoc.Typography.monoLabel10_5)
                        .foregroundColor(Theme.Colors.ink3)
                        .padding(.trailing, 4)
                }
                ChipFlowLayout(spacing: 6) {
                    ForEach(variants) { variant in
                        let on = variant.id == selectedId
                        Button { onSelect(variant.id) } label: {
                            Text(variant.label)
                                .knockTextStyle(Theme.AskDoc.Typography.chip12_5)
                                .foregroundColor(on ? Theme.AskDoc.Colors.variantOnText : Theme.Colors.ink2)
                                .padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                                .background(on ? Theme.Colors.honeySoft : Theme.Colors.win)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(on ? Theme.Colors.honey500 : Theme.Colors.line, lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain).pointerCursor()
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(Rectangle().fill(Theme.Colors.line).frame(height: 1), alignment: .bottom)
        }
    }
}

/// The artifact live beside the questions: about 520 pt, its variant chips, Reset, Comment, close and Esc.
struct ArtifactPanelView: View {
    @ObservedObject var controller: AskDocController
    let open: OpenArtifact
    /// WAG-280: the answer is already sent, so the viewer offers no Comment.
    var isLocked = false

    private var question: Question? {
        controller.doc?.questions.first { $0.id == open.questionId }
    }

    var body: some View {
        VStack(spacing: 0) {
            ArtifactHeaderBar(
                card: open.card,
                subtitle: question.flatMap { q in controller.doc.map { "\($0.sectionLabel(of: q).capitalized.replacingOccurrences(of: " Of ", with: " of ")) · \(AgentMarkdown.singleLine(q.title))" } },
                leading: EmptyView(),
                onReset: { controller.viewer.pageFragment = controller.fragment(for: open.questionId); reload() },
                commentsStore: controller.viewer.commentsStore,
                viewer: controller.viewer,
                onClose: controller.close)
            if let question, let doc = controller.doc {
                VariantChipsView(question: question, selectedId: doc.selectedVariant(for: question)) {
                    controller.selectVariant($0, question: question.id)
                }
            }
            ArtifactViewerView(viewModel: controller.viewer, isLocked: isLocked)
            if let doc = controller.doc, doc.isStepped { stepFooter(doc) }
        }
        .frame(width: Theme.AskDoc.Metrics.panelWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.Colors.win)
        .overlay(Rectangle().fill(Theme.Colors.line).frame(width: 1), alignment: .leading)
        .shadow(color: Theme.Colors.shadowBlack.opacity(0.10), radius: 16, x: -8, y: 0)
        .background(EscapeKeyCatcher(
            shouldHandle: { !HomeLink.textInputHasFocus(in: $0) },
            onEscape: controller.close))
    }

    /// The same Back and Next as the bottom bar: the panel shows the question of the current step.
    private func stepFooter(_ doc: QuestionsDocModel) -> some View {
        HStack(spacing: 10) {
            if doc.canGoBack { StepBackButton { controller.doc?.back() } }
            Text(doc.stepCrumb)
                .knockTextStyle(Theme.AskDoc.Typography.crumbs12)
                .foregroundColor(Theme.AskDoc.Colors.quiet)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let next = doc.nextLabel { StepNextButton(label: next) { controller.doc?.next() } }
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        .overlay(Rectangle().fill(Theme.Colors.line).frame(height: 1), alignment: .top)
    }

    private func reload() {
        guard let detail = controller.viewer.detail else { return }
        Task { await controller.viewer.load(detail: detail) }
    }
}

/// The artifact on the whole page, with a way back to the questions.
struct ArtifactFullPageView: View {
    @ObservedObject var controller: AskDocController
    let open: OpenArtifact
    var isLocked = false

    private var question: Question? { controller.doc?.questions.first { $0.id == open.questionId } }

    var body: some View {
        VStack(spacing: 0) {
            ArtifactHeaderBar(
                card: open.card,
                subtitle: question.map { AgentMarkdown.singleLine($0.title) },
                leading: backButton,
                onReset: { controller.viewer.pageFragment = controller.fragment(for: open.questionId) },
                commentsStore: controller.viewer.commentsStore,
                viewer: controller.viewer,
                onClose: nil)
            if let question, let doc = controller.doc {
                VariantChipsView(question: question, selectedId: doc.selectedVariant(for: question)) {
                    controller.selectVariant($0, question: question.id)
                }
            }
            ArtifactViewerView(viewModel: controller.viewer, isLocked: isLocked)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.win)
        .background(EscapeKeyCatcher(
            shouldHandle: { !HomeLink.textInputHasFocus(in: $0) },
            onEscape: controller.close))
    }

    private var backButton: some View {
        Button(action: controller.close) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                Text("Back to the questions").knockTextStyle(Theme.Typography.buttonSm12_5w600)
            }
            .foregroundColor(Theme.Colors.ink)
            .padding(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 12))
            .background(Theme.Colors.side)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
    }
}

/// What "In its own window" opens: one artifact of one ask, in a window of its own.
struct ArtifactWindowRequest: Codable, Hashable {
    static let sceneID = "artifact"
    let caseId: String
    let fragment: String?
    let title: String
    /// The revision to show (WAG-291: the artifact tab that was on show); `nil` is the newest.
    var revision: Int?
}

struct ArtifactWindowView: View {
    let request: ArtifactWindowRequest
    let client: KnockClient
    @StateObject private var viewer: ReviewViewModel

    /// `commentsStore` is the case's one store (`AppModel.commentsStore(forCase:)`), so a pin placed in this
    /// window shows on the case page and goes out with its reply (WAG-280).
    init(request: ArtifactWindowRequest, client: KnockClient, commentsStore: CommentsSessionStore = CommentsSessionStore()) {
        self.request = request
        self.client = client
        _viewer = StateObject(wrappedValue: ReviewViewModel(client: client, commentsStore: commentsStore))
    }

    /// The answer is sent (or on its way): no new comment.
    private var isLocked: Bool {
        guard let detail = viewer.detail else { return true }
        return detail.case.replyLockState != .editable
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                CommentsWindowButton(store: viewer.commentsStore, viewer: viewer)
            }
            .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
            .overlay(Rectangle().fill(Theme.Colors.line).frame(height: 1), alignment: .bottom)
            ArtifactViewerView(viewModel: viewer, isLocked: isLocked)
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(Theme.Colors.win)
        .preferredColorScheme(.light)
        .task {
            viewer.pageFragment = request.fragment
            if let detail = try? await client.casesGet(id: request.caseId) { await viewer.load(detail: detail, revision: request.revision) }
        }
        .navigationTitle(request.title)
    }
}

/// The own window's "N comments" button: the same list as the case page's header.
private struct CommentsWindowButton: View {
    @ObservedObject var store: CommentsSessionStore
    var viewer: ReviewViewModel? = nil
    @State private var showsComments = false

    var body: some View {
        Button { showsComments.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "text.bubble").font(.system(size: 10))
                Text(ArtifactHeaderBar<EmptyView>.commentsLabel(store.model.comments.count)).knockTextStyle(Theme.AskDoc.Typography.chip12_5)
            }
            .foregroundColor(Theme.Colors.ink2)
            .padding(EdgeInsets(top: 3, leading: 9, bottom: 3, trailing: 9))
            .background(Theme.Colors.win)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.Colors.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .popover(isPresented: $showsComments, arrowEdge: .bottom) {
            CaseCommentsListView(
                store: store, context: viewer?.commentViewContext ?? .unknown,
                onShow: { viewer?.showComment($0) })
        }
    }
}
