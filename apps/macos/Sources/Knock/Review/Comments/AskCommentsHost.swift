import SwiftUI

/// WAG-357: wraps a request page. It gives the page its `AskCommentsHub` and draws, over the page, the Comment button
/// at a selection, the new-note popover, the hover note and the saved note (to edit or delete). They are drawn here
/// and not inside the text views, which are small and would clip them.
struct AskCommentsHost<Content: View>: View {
    let hub: AskCommentsHub
    let content: Content
    /// WAG-384: sends the "Explain" request for the selected text (the Explain button and the E key).
    let onExplain: ((String) -> Void)?

    init(hub: AskCommentsHub, onExplain: ((String) -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.hub = hub
        self.onExplain = onExplain
        self.content = content()
    }

    var body: some View {
        content
            .environment(\.askComments, hub)
            .environment(\.explainSelection, onExplain)
            .onAppear { hub.onExplain = onExplain }
            .coordinateSpace(name: AskCommentsHub.space)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) {
                EvidenceLayoutLog.event("askHostSize", "\($0.width)x\($0.height)")
                hub.ui.setHostSize($0)
            }
            .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named(AskCommentsHub.space)).onEnded {
                hub.hostClicked(at: $0.location)
            })
            .overlay(alignment: .topLeading) { AskCommentsOverlay(hub: hub, ui: hub.ui) }
    }
}

extension AskCommentsHub {
    /// A click on the page that is not on a text: the popover and the saved note close. A click inside one stays.
    func hostClicked(at point: CGPoint) {
        guard ui.draft != nil || ui.open != nil else { return }
        if ui.overlayFrames.values.contains(where: { $0.contains(point) }) { return }
        pointerDown()
    }
}

private struct AskCommentsOverlay: View {
    let hub: AskCommentsHub
    @ObservedObject var ui: AskCommentsUI

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let selection = ui.selection, ui.draft == nil, let rect = ui.hostRect(key: selection.key, local: selection.rect) {
                AskPlaced(id: "button", ui: ui, anchor: rect) {
                    MarkdownCommentButton(
                        onTap: { hub.beginDraft() },
                        onExplain: hub.onExplain == nil ? nil : { hub.explainSelection() })
                }
            }
            if let draft = ui.draft, let rect = ui.hostRect(key: draft.key, local: draft.rect) {
                AskPlaced(id: "draft", ui: ui, anchor: rect) {
                    MarkdownDraftNoteView(
                        number: hub.nextNumber, targetLabel: draft.target.part.words, text: draft.text,
                        onSave: { hub.saveDraft($0) }, onCancel: { hub.cancelDraft() })
                }
            }
            if let open = ui.open, let comment = hub.comment(id: open.commentId), let rect = ui.hostRect(key: open.key, local: open.rect) {
                AskPlaced(id: "note", ui: ui, anchor: rect) {
                    savedNote(comment)
                }
            }
            if let hover = ui.hover, ui.open == nil, ui.draft == nil, let comment = hub.comment(id: hover.commentId),
               let rect = ui.hostRect(key: hover.key, local: hover.rect) {
                AskPlaced(id: "hover", ui: ui, anchor: rect) { MarkdownHoverNoteView(text: comment.text) }
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(ui.selection != nil || ui.draft != nil || ui.open != nil)
    }

    @ViewBuilder
    private func savedNote(_ comment: Comment) -> some View {
        let words = comment.askAnchor?.part.words ?? "the request"
        if hub.canComment, hub.isPending(comment.id) {
            InlineCommentCardView(
                number: comment.n, label: words, text: comment.text,
                onSave: { hub.saveNote(id: comment.id, text: $0) }, onDelete: { hub.deleteNote(id: comment.id) },
                onClose: { hub.closeNote() })
        } else {
            // A sent comment is read only.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    PinView(number: comment.n, size: Theme.Spacing.pinSmall)
                    Text("Note on \(words)").knockTextStyle(Theme.Typography.badgeLabel11w500).foregroundColor(Theme.Colors.ink3)
                }
                Text(comment.text).knockTextStyle(Theme.Typography.body12_5w400).foregroundColor(Theme.Colors.ink)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            .notePopoverChrome()
            .padding(EdgeInsets(top: 4, leading: 4, bottom: 18, trailing: 18))
            .onExitCommand { hub.closeNote() }
        }
    }
}

/// Puts a view under an anchor rect (host space), kept inside the host. It opens above the anchor when there is no room below.
private struct AskPlaced<Content: View>: View {
    let id: String
    @ObservedObject var ui: AskCommentsUI
    let anchor: CGRect
    @ViewBuilder let content: Content
    @State private var size: CGSize = .zero

    var body: some View {
        let origin = AskPlacement.origin(anchor: anchor, size: size, host: ui.hostSize)
        content
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
            .offset(x: origin.x, y: origin.y)
            .onChange(of: origin) { _, new in ui.overlayFrames[id] = CGRect(origin: new, size: size) }
            .onAppear { ui.overlayFrames[id] = CGRect(origin: origin, size: size) }
            .onDisappear { ui.overlayFrames[id] = nil }
    }
}

/// Where the button and the popovers go. Plain geometry, so a test can check it.
enum AskPlacement {
    static func origin(anchor: CGRect, size: CGSize, host: CGSize) -> CGPoint {
        var x = anchor.minX - 4
        if host.width > 0, size.width > 0 { x = min(x, host.width - size.width - 4) }
        x = max(x, 4)
        var y = anchor.maxY - 2
        if host.height > 0, size.height > 0, y + size.height > host.height - 8 {
            y = max(8, anchor.minY - size.height + 18)
        }
        return CGPoint(x: x, y: y)
    }
}
