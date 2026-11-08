import AppKit
import SwiftUI

/// WAG-357: the view of one commentable piece of request text. `SourcedText` and `AgentMarkdownText` use it when
/// they get a `target` and the page has an `AskCommentsHub`; everything else keeps drawing as before.
struct CommentableAskText: View {
    let text: String
    var prefix: String? = nil
    var mode: AskTextContent.Mode = .line
    let style: Theme.TextStyle
    var weight: NSFont.Weight = .regular
    var mono = false
    let color: Color
    let target: AskCommentTarget
    @ObservedObject var hub: AskCommentsHub

    @Environment(\.sourcesHub) private var sourcesHub
    /// Where the text sits in the sources host, in a box rather than a `@State` point: it moves on every frame of
    /// a scroll, and a state write there re-rendered every text and laid out the whole window per frame
    /// (waggle-releases#9). The text view reads it straight from the box.
    @State private var sourcesOrigin = SourcesOriginBox()
    @State private var cache = ContentCache()

    private func makeFace() -> AskTextFace {
        var face = AskTextFace(style: style, weight: weight, color: color)
        face.mono = mono
        return face
    }

    var body: some View {
        let _ = EvidenceLayoutLog.bump("body.askText")
        let face = makeFace()
        let content = cache.content(
            text: text, prefix: prefix, mode: mode, face: face, book: sourcesHub?.book)
        let comments = hub.comments(for: target, length: content.plainLength)
        AskTextRepresentable(
            content: content, target: target, comments: comments, selectedId: hub.store?.selectedCommentId,
            canComment: hub.canComment, hub: hub, sourcesHub: sourcesHub, sourcesOrigin: sourcesOrigin)
            .padding(.horizontal, -AskCommentTextView.inset.width)
            .padding(.vertical, -AskCommentTextView.inset.height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .alignmentGuide(.firstTextBaseline) { _ in cache.baseline }
            .onGeometryChange(for: CGPoint.self, of: { $0.frame(in: .named(AskCommentsHub.space)).origin }) {
                EvidenceLayoutLog.event("viewMoved.call", "\(EvidenceLayoutLog.safe(target.key)) at \($0.x),\($0.y)")
                hub.viewMoved(key: target.key, origin: CGPoint(
                    x: $0.x - AskCommentTextView.inset.width, y: $0.y - AskCommentTextView.inset.height))
            }
            .onGeometryChange(for: CGPoint.self, of: { $0.frame(in: .named(SourcesHub.space)).origin }) {
                let next = CGPoint(x: $0.x - AskCommentTextView.inset.width, y: $0.y - AskCommentTextView.inset.height)
                sourcesOrigin.move(to: next)
            }
            .onDisappear { hub.viewGone(key: target.key) }
    }
}

/// Hands the text's place in the sources host to its text view, outside SwiftUI's state.
@MainActor
final class SourcesOriginBox {
    private(set) var origin: CGPoint = .zero
    weak var view: AskCommentTextView?

    func move(to next: CGPoint) {
        // Half a point is the same place (WAG-365): a fraction must not start a new pass.
        guard abs(next.x - origin.x) > AskCommentsUI.tolerance || abs(next.y - origin.y) > AskCommentsUI.tolerance else { return }
        origin = next
        view?.sourcesOrigin = next
    }
}

/// Builds the content once for the same inputs, so a redraw from the pointer does not lay the text out again.
private final class ContentCache {
    private var key: Key?
    private var content: AskTextContent?
    private(set) var baseline: CGFloat = 0

    private struct Key: Equatable {
        let text: String
        let prefix: String?
        let mode: AskTextContent.Mode
        let face: AskTextFace
        let book: SourceBook?
    }

    func content(text: String, prefix: String?, mode: AskTextContent.Mode, face: AskTextFace, book: SourceBook?) -> AskTextContent {
        let next = Key(text: text, prefix: prefix, mode: mode, face: face, book: book)
        if next == key, let content { return content }
        let built = AskTextContent.build(text: text, mode: mode, face: face, book: book, showsPills: true, prefix: prefix)
        key = next
        content = built
        baseline = AskTextContent.firstBaseline(of: built.attributed)
        return built
    }
}

private struct AskTextRepresentable: NSViewRepresentable {
    let content: AskTextContent
    let target: AskCommentTarget
    let comments: [Comment]
    let selectedId: String?
    let canComment: Bool
    let hub: AskCommentsHub
    let sourcesHub: SourcesHub?
    let sourcesOrigin: SourcesOriginBox

    func makeNSView(context: Context) -> AskCommentTextView {
        let view = AskCommentTextView.make()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: AskCommentTextView, context: Context) {
        apply(to: view)
    }

    static func dismantleNSView(_ view: AskCommentTextView, coordinator: ()) {
        view.forgetPills()
    }

    private func apply(to view: AskCommentTextView) {
        view.configure(
            content: content, target: target, comments: comments, selectedId: selectedId, canComment: canComment,
            hub: hub, sourcesHub: sourcesHub)
        sourcesOrigin.view = view
        view.sourcesOrigin = sourcesOrigin.origin
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AskCommentTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 600
        EvidenceLayoutLog.event("fits", "w=\(width) key=\(EvidenceLayoutLog.safe(target.key))")
        return CGSize(width: width, height: nsView.fittingHeight(forWidth: width))
    }
}
