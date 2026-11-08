import SwiftUI

/// The review workspace's right column in Comment mode (docs/design/mvp-values.md
/// §M5 `uyrRs`, fixed width 430pt — same width as `AskColumnView`, which this
/// replaces while `mode == .comment`): every comment of the case as one flat
/// numbered list (HAIL-75), oldest first, and the composer footer
/// (docs/design/mvp-values.md §M7 panel C).
///
/// HAIL-35 contract: earlier comments must never look lost after re-entering
/// Comment mode, so this lists every comment in `store.model`, not just the
/// ones on the capture shown on the stage. Clicking a card highlights its pin
/// on the artifact; clicking a pin scrolls its card into view here.
struct CommentsColumnView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: CommentsSessionStore
    @ObservedObject var composer: ComposerViewModel
    @ObservedObject var sendFlow: SendFlowController
    /// WAG-397: the shared page's team thread joins the list, and the composer can post on the page.
    @ObservedObject var shared: SharingModel
    @State private var chosenTarget = MergedComments.Target.agent
    /// The right column's Question | Comments switch (HAIL-56 contract).
    let tab: ReviewColumnTab
    var onSelectTab: (ReviewColumnTab) -> Void = { _ in }
    /// WAG-307: what the stage shows, so a comment whose page state is gone lands under "On other views".
    var context = CommentViewContext.unknown
    var onShow: (Comment) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ReviewColumnTabsView(tab: tab, commentCount: store.model.comments.count, onSelect: onSelectTab)
                            .padding(.bottom, 8)
                        CommentListView(store: store, context: context, onShow: onShow, sharing: shared)
                    }
                    .padding(EdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: store.revealRequest) { _, request in
                    guard let request, request.origin == .artifact else { return }
                    ReducedMotion.animate(reduceMotion: reduceMotion, .easeOut(duration: 0.2)) { scrollProxy.scrollTo(request.commentId, anchor: .center) }
                }
            }
            if let notice = store.captureNotice {
                Text(notice)
                    .knockTextStyle(Theme.Typography.statusCaption11w400)
                    .foregroundColor(Theme.Colors.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 8, leading: 24, bottom: 8, trailing: 24))
                    .onTapGesture { store.dismissCaptureNotice() }.pointerCursor()
            }
            if shared.canWriteOnPage {
                ComposerTargetSwitch(target: $chosenTarget)
            }
            if target == .page {
                PageComposerView(model: shared)
            } else {
                agentComposer
            }
        }
        .frame(minWidth: 340, idealWidth: 430, maxWidth: 430)
        .frame(maxHeight: .infinity)
        .background(Theme.Colors.win)
    }

    private var target: MergedComments.Target { MergedComments.effectiveTarget(chosenTarget, canWriteOnPage: shared.canWriteOnPage) }

    private var agentComposer: some View {
        VStack(spacing: 0) {
            ComposerFooterView(
                composer: composer,
                sendFlow: sendFlow,
                deliveryState: sendFlow.deliveryState,
                // Every comment across every capture (HAIL-35 contract: "the
                // footer counts ALL comments, same as Interact mode's
                // commentCount"), not just the capture currently shown.
                commentCount: store.model.comments.count,
                placeholder: shared.canWriteOnPage ? MergedComments.placeholder(.agent) : PromptBarLogic.placeholder(.revision),
                inputBackground: Theme.Colors.list,
                maxReplyLines: PromptBarLogic.workspaceMaxLines
            )
        }
    }
}

/// WAG-397: the two-way switch above the composer, in the look of the Decision | Comments switch.
struct ComposerTargetSwitch: View {
    @Binding var target: MergedComments.Target

    var body: some View {
        HStack(spacing: 2) {
            segment(.agent)
            segment(.page)
        }
        .padding(3)
        .background(Theme.Colors.side)
        .cornerRadius(Theme.Radius.columnTabsTrack)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 10, leading: 24, bottom: 8, trailing: 24))
        .background(Theme.Colors.win)
    }

    private func segment(_ value: MergedComments.Target) -> some View {
        let chosen = target == value
        return Button { target = value } label: {
            Text(MergedComments.title(value))
                .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                .foregroundColor(chosen ? Theme.Colors.ink : Theme.Colors.ink2)
                .padding(.vertical, 5)
                .padding(.horizontal, 12)
                .background(chosen ? Theme.Colors.win : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.columnTabsTrack - 3))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: chosen)
        .pointerCursor()
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }
}

/// WAG-397: the composer for "On the page". It posts an owner comment to the shared page and nowhere else.
struct PageComposerView: View {
    @ObservedObject var model: SharingModel
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let canSend = CommentThreads.canSend(draft, busy: model.posting, commentsClosed: model.commentsClosed)
        VStack(alignment: .leading, spacing: 6) {
            if let problem = model.pageProblem {
                Text(problem)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(MergedComments.pagePlaceholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($focused)
                    .accessibilityLabel(MergedComments.pagePlaceholder)
                    .knockTextStyle(Theme.Typography.body13w400)
                    .foregroundColor(Theme.Colors.ink)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(Theme.Colors.list)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(focused ? Theme.Colors.honey500 : Theme.Colors.line, lineWidth: 1))
                Button { send() } label: {
                    Text(model.posting ? "Posting..." : "Post")
                        .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                        .foregroundColor(canSend ? Theme.Colors.ink : Theme.Colors.ink3)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 12)
                        .background(canSend ? Theme.Colors.honeySoft : Theme.Colors.side)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                .pointerCursor()
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
        .background(Theme.Colors.win.shadow(Theme.Shadow.dockUp))
        .overlay(Rectangle().fill(Theme.Colors.line2).frame(height: 1), alignment: .top)
    }

    private func send() {
        let text = draft
        Task { if await model.commentOnPage(text) { draft = "" } }
    }
}
