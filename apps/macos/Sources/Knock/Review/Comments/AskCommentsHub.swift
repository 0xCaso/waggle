import AppKit
import Combine
import SwiftUI

/// WAG-357: the comments on the text of one request page. The text views (`CommentableAskText`) read the saved
/// comments from here and report what the person selects. `AskCommentsHost` draws the Comment button, the note
/// popover and the saved note, so nothing is clipped by a small text view.
///
/// The saved comments live in the case's `CommentsSessionStore` (one number sequence with the artifact comments).
/// `sent` holds the comments of a sent reply, shown read only.
@MainActor
final class AskCommentsHub: ObservableObject {
    static let space = "askCommentsHost"

    let store: CommentsSessionStore?
    /// False when the answer is locked (sent): highlights show, nothing can be added or edited.
    @Published var canComment: Bool
    /// The request comments of the sent reply of this round, read only.
    @Published private(set) var sent: [Comment] = []
    /// WAG-384: sends the "Explain" request for the selected text; `nil` hides the Explain button.
    var onExplain: ((String) -> Void)?
    /// The transient state the host draws: selection, draft, open note, hover.
    let ui = AskCommentsUI()

    private var bag = Set<AnyCancellable>()
    private let views = NSHashTable<AskCommentTextView>.weakObjects()

    init(store: CommentsSessionStore?, canComment: Bool = true) {
        self.store = store
        self.canComment = canComment
        // A comment saved, edited or deleted redraws every text.
        store?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        ui.onDraftChange = { [weak self] in self?.views.allObjects.forEach { $0.refreshHighlights() } }
    }

    func setSent(_ comments: [Comment]) {
        let asks = comments.filter(\.isAsk)
        if asks != sent { sent = asks }
    }

    // MARK: Comments

    /// The comments to draw: the pending ones, then the sent ones that are not pending.
    var allComments: [Comment] {
        let pending = store?.model.askComments ?? []
        let ids = Set(pending.map(\.id))
        return pending + sent.filter { !ids.contains($0.id) }
    }

    /// The comments that sit on this view's text.
    func comments(for target: AskCommentTarget, length: Int) -> [Comment] {
        allComments.filter { comment in
            guard let anchor = comment.askAnchor, target.owns(anchor) else { return false }
            return anchor.start >= target.baseOffset && anchor.end <= target.baseOffset + length
        }
    }

    var nextNumber: Int { store?.nextPinNumber ?? 1 }

    func isPending(_ id: String) -> Bool { store?.model.comments.contains { $0.id == id } == true }
    func comment(id: String) -> Comment? { allComments.first { $0.id == id } }

    // MARK: Views

    func register(_ view: AskCommentTextView) { views.add(view) }

    /// One selection at a time: a new selection clears the others.
    func willSelect(in view: AskCommentTextView) {
        for other in views.allObjects where other !== view && other.selectedRange().length > 0 {
            other.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    // MARK: Selection and draft

    func selectionChanged(key: String, target: AskCommentTarget, anchor: AskTextAnchor?, rect: CGRect) {
        let active = views.allObjects.map { AskSelectionRule.PartSelection(key: $0.target.key, hasSelection: $0.selectedRange().length > 0) }
        guard canComment, let anchor, ui.draft == nil, AskSelectionRule.single(active) == key else {
            if ui.selection?.key == key { ui.selection = nil }
            return
        }
        EvidenceLayoutLog.event("selection.set", "\(EvidenceLayoutLog.safe(key))")
        ui.selection = AskCommentsUI.Selection(key: key, target: target, anchor: anchor, rect: rect)
    }

    func selectionCleared(key: String) {
        if ui.selection?.key == key { ui.selection = nil }
    }

    /// The Comment button or the C key.
    func beginDraft(initialText: String = "") {
        guard canComment, let selection = ui.selection else { return }
        ui.selection = nil
        ui.open = nil
        EvidenceLayoutLog.event("draft.set", "\(EvidenceLayoutLog.safe(selection.key))")
        ui.draft = AskCommentsUI.Draft(
            key: selection.key, target: selection.target, anchor: selection.anchor, rect: selection.rect, text: initialText)
    }

    /// The Explain button or the E key (WAG-384).
    func explainSelection() {
        guard canComment, let onExplain, let selection = ui.selection else { return }
        ui.selection = nil
        onExplain(selection.anchor.quote)
    }

    func saveDraft(_ text: String) {
        guard let draft = ui.draft else { return }
        ui.draft = nil
        if let comment = store?.addAskComment(anchor: draft.anchor, text: text) {
            store?.selectComment(id: comment.id, origin: .artifact)
        }
    }

    func cancelDraft() { ui.draft = nil }

    // MARK: Saved notes

    func openNote(id: String, key: String, rect: CGRect) {
        ui.selection = nil
        ui.draft = nil
        ui.hover = nil
        EvidenceLayoutLog.event("note.open", "\(EvidenceLayoutLog.safe(key))")
        ui.open = AskCommentsUI.Note(commentId: id, key: key, rect: rect)
    }

    func closeNote() { ui.open = nil }

    func saveNote(id: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store?.updateComment(id: id, text: trimmed)
        ui.open = nil
    }

    func deleteNote(id: String) {
        store?.deleteComment(id: id)
        ui.open = nil
    }

    func hoverChanged(id: String?, key: String, rect: CGRect) {
        guard ui.open == nil, ui.draft == nil else { return }
        ui.hover = id.map { AskCommentsUI.Note(commentId: $0, key: key, rect: rect) }
    }

    /// A press on any text of the page: the open popover or note closes.
    func pointerDown() {
        ui.draft = nil
        ui.open = nil
        ui.hover = nil
    }

    /// Where a view sits in the host, for the overlays.
    func viewMoved(key: String, origin: CGPoint) {
        ui.setOrigin(origin, key: key)
    }

    func viewGone(key: String) {
        ui.forgetOrigin(key: key)
        if ui.selection?.key == key { ui.selection = nil }
        if ui.hover?.key == key { ui.hover = nil }
    }
}

/// The part of the hub that changes with the pointer. Only the host reads it, so a text does not redraw on hover.
@MainActor
final class AskCommentsUI: ObservableObject {
    struct Selection: Equatable {
        let key: String
        let target: AskCommentTarget
        let anchor: AskTextAnchor
        /// In the text view's own coordinates.
        let rect: CGRect
    }

    struct Draft: Equatable {
        let key: String
        let target: AskCommentTarget
        let anchor: AskTextAnchor
        let rect: CGRect
        let text: String
    }

    struct Note: Equatable {
        let commentId: String
        let key: String
        let rect: CGRect
    }

    @Published var selection: Selection?
    @Published var draft: Draft? { didSet { if oldValue != draft { onDraftChange() } } }
    var onDraftChange: () -> Void = {}
    @Published var open: Note?
    @Published var hover: Note?
    /// Not published (WAG-365): a write from a geometry action must not invalidate the page. The overlay reads them
    /// when it draws, and `touch` tells it to draw again only while something of the key is on screen.
    private(set) var origins: [String: CGPoint] = [:]
    private(set) var hostSize: CGSize = .zero
    /// How many times a position or the host size changed for real. Tests read it.
    private(set) var geometryWrites = 0
    /// The frames of the popover and the note, so a click inside them is not "outside".
    var overlayFrames: [String: CGRect] = [:]

    /// Half a point: a stored position that differs by less is the same position.
    static let tolerance: CGFloat = 0.5

    func setOrigin(_ origin: CGPoint, key: String) {
        if let old = origins[key], abs(old.x - origin.x) <= Self.tolerance, abs(old.y - origin.y) <= Self.tolerance { return }
        EvidenceLayoutLog.event("origin.write", "\(EvidenceLayoutLog.safe(key)) old=\(String(describing: origins[key])) new=\(origin)")
        origins[key] = origin
        geometryWrites += 1
        if showsOverlay(of: key) { objectWillChange.send() }
    }

    func forgetOrigin(key: String) {
        guard origins.removeValue(forKey: key) != nil else { return }
        if showsOverlay(of: key) { objectWillChange.send() }
    }

    func setHostSize(_ size: CGSize) {
        if abs(hostSize.width - size.width) <= Self.tolerance, abs(hostSize.height - size.height) <= Self.tolerance { return }
        hostSize = size
        geometryWrites += 1
        if hasOverlay { objectWillChange.send() }
    }

    private var hasOverlay: Bool { selection != nil || draft != nil || open != nil || hover != nil }

    private func showsOverlay(of key: String) -> Bool {
        selection?.key == key || draft?.key == key || open?.key == key || hover?.key == key
    }

    func hostRect(key: String, local: CGRect) -> CGRect? {
        origins[key].map { local.offsetBy(dx: $0.x, dy: $0.y) }
    }
}

private struct AskCommentsHubKey: EnvironmentKey {
    static let defaultValue: AskCommentsHub? = nil
}

extension EnvironmentValues {
    /// The comments on the text of the request page on screen. `nil` outside it: agent text is not commentable there.
    var askComments: AskCommentsHub? {
        get { self[AskCommentsHubKey.self] }
        set { self[AskCommentsHubKey.self] = newValue }
    }
}

/// Which request comments belong to the round on screen: those of a reply sent at or after the round began.
enum AskCommentsRound {
    static func comments(replies: [Reply], roundStart: Date?) -> [Comment] {
        replies.filter { $0.replacedAt == nil }.filter { reply in
            guard let roundStart else { return true }
            return (KnockDateFormat.date(from: reply.createdAt) ?? .distantPast) >= roundStart
        }.flatMap(\.comments).filter(\.isAsk)
    }
}

extension AskCommentsHub {
    /// Sets what depends on the case: whether the person can still comment, and the sent comments of this round.
    func sync(detail: CaseDetail, canComment: Bool) {
        if self.canComment != canComment { self.canComment = canComment }
        let start = detail.case.optionsUpdatedAt.flatMap { KnockDateFormat.date(from: $0) }
        setSent(AskCommentsRound.comments(replies: detail.replies, roundStart: start))
    }
}
