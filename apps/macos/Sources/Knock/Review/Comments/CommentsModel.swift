import Foundation

/// A frozen visual state taken in Comment mode (docs/protocol-mvp.md
/// "capture"). This is the UI-local record of *when* a capture was taken and
/// *which* revision it froze; the pixels live in `CommentsSessionStore`
/// (an `NSImage`, kept out of this file so the numbering/normalization
/// logic here stays a plain, platform-independent model). The wire `Capture`
/// type (Nouns.swift), which additionally carries the PNG bytes for
/// `reply.submit`, is assembled from this plus the stored image at send
/// time (KNOCK-12).
struct CaptureRecord: Identifiable, Equatable {
    let id: String
    let revision: Int
    /// "Capture n", 1-based, in the order captures were taken for this case.
    let n: Int
    let takenAt: Date
    /// Where the operator was scrolled to in Interact mode when this capture
    /// was taken, 0...1 of the full page (HAIL-35 contract: "first scrolled
    /// to where the operator was in Interact mode"). `0` for a screenshot
    /// (no Interact scroll to inherit) and for a restored capture (HAIL-34
    /// "Change answer" replies carry no scroll position on the wire).
    let scrollFraction: Double
    /// HAIL-75: where the live page was when this capture was taken (the
    /// captured viewport's scroll offset and size, in points), so a comment's
    /// viewport-relative rect can be mapped back onto the page. `nil` for a
    /// screenshot and for a restored capture. App side only; never sent.
    var page: PageViewport? = nil
    /// HAIL-103: the view (hash and fingerprint) the live page was on when this
    /// capture was taken. `nil` for a screenshot and for a restored capture.
    /// App side only; never sent.
    var view: PageView? = nil
}

/// Pin numbering and normalized-rect storage for one case's Comment mode
/// (docs/stories/KNOCK-11.md). Reuses the wire `Comment` type (Nouns.swift:
/// `id`, `captureId`, `n`, `rect`, `text`) directly for saved pins, since
/// that is exactly the shape `reply.submit` needs later.
///
/// HAIL-75: `n` is numbered per case, 1...N in the order the comments were
/// made, and the same number shows in the list, on the pin and in the
/// annotated PNG. A delete renumbers every comment after it, gapless.
struct CommentsModel: Equatable {
    private(set) var captures: [CaptureRecord] = []
    private(set) var comments: [Comment] = []
    /// HAIL-240: the page element a pin on a live prototype points at, by comment id. App side
    /// only; it reaches the agent inside the comment text (`ReplyPayloadBuilder`).
    private(set) var elementContexts: [String: PageElementContext] = [:]

    mutating func setElementContext(_ context: PageElementContext?, forComment id: String) {
        guard comments.contains(where: { $0.id == id }) else { return }
        elementContexts[id] = context
    }

    @discardableResult
    mutating func addCapture(revision: Int, takenAt: Date = Date(), id: String = UUID().uuidString, scrollFraction: Double = 0, page: PageViewport? = nil, view: PageView? = nil) -> CaptureRecord {
        let record = CaptureRecord(id: id, revision: revision, n: captures.count + 1, takenAt: takenAt, scrollFraction: scrollFraction, page: page, view: view)
        captures.append(record)
        return record
    }

    /// Sets the page view a capture was taken on, once it is known (HAIL-112:
    /// a live capture is saved before its view has been read).
    mutating func setView(_ view: PageView?, onCapture id: String) {
        guard let index = captures.firstIndex(where: { $0.id == id }) else { return }
        captures[index].view = view
    }

    /// Captures that hold at least one comment, oldest first. Only these are
    /// listed, counted and sent (HAIL-65: an empty capture never shows).
    var commentedCaptures: [CaptureRecord] {
        let ids = Set(comments.map(\.captureId))
        return captures.filter { ids.contains($0.id) }
    }

    /// Removes a capture and every comment on it, then renumbers the captures
    /// that follow so "Capture N" stays gapless (HAIL-65).
    @discardableResult
    mutating func deleteCapture(id: String) -> Bool {
        guard captures.contains(where: { $0.id == id }) else { return false }
        comments.removeAll { $0.captureId == id }
        captures.removeAll { $0.id == id }
        renumberCaptures()
        renumber()
        return true
    }

    /// Drops every capture that has no comment (HAIL-65 cleanup) and returns
    /// the ids removed, so the caller can free their images.
    @discardableResult
    mutating func pruneEmptyCaptures(keeping kept: Set<String> = []) -> [String] {
        let commented = Set(comments.map(\.captureId))
        let removed = captures.filter { !commented.contains($0.id) && !kept.contains($0.id) }.map(\.id)
        guard !removed.isEmpty else { return [] }
        captures.removeAll { removed.contains($0.id) }
        renumberCaptures()
        return removed
    }

    private mutating func renumberCaptures() {
        captures = captures.enumerated().map { index, capture in
            CaptureRecord(id: capture.id, revision: capture.revision, n: index + 1, takenAt: capture.takenAt, scrollFraction: capture.scrollFraction, page: capture.page, view: capture.view)
        }
    }

    /// Saved comments on one capture, in creation (`n`) order.
    func comments(on captureId: String) -> [Comment] {
        comments.filter { $0.captureId == captureId }.sorted { $0.n < $1.n }
    }

    @discardableResult
    mutating func addComment(captureId: String, rect: Rect, text: String, id: String = UUID().uuidString) -> Comment {
        let n = comments.count + 1
        let comment = Comment(id: id, captureId: captureId, n: n, rect: rect, text: text)
        comments.append(comment)
        return comment
    }

    /// Adds a comment on a range of a markdown revision's source (HAIL-150). Numbered case-wide
    /// like every other comment.
    @discardableResult
    mutating func addTextComment(anchor: TextAnchor, text: String, id: String = UUID().uuidString) -> Comment {
        let comment = Comment(id: id, n: comments.count + 1, anchor: anchor, text: text)
        comments.append(comment)
        return comment
    }

    /// Adds a comment on the text of a request (WAG-357). Numbered case-wide like every other comment.
    @discardableResult
    mutating func addAskComment(anchor: AskTextAnchor, text: String, id: String = UUID().uuidString) -> Comment {
        let comment = Comment(id: id, n: comments.count + 1, askAnchor: anchor, text: text)
        comments.append(comment)
        return comment
    }

    /// Comments on the text of the request, in number order (WAG-357).
    var askComments: [Comment] { orderedComments.filter(\.isAsk) }

    /// Text comments made on `revision`, in number order (HAIL-150). A comment stays on the
    /// revision it was made on.
    func textComments(onRevision revision: Int) -> [Comment] {
        orderedComments.filter { $0.anchor?.revision == revision }
    }

    /// Edits a saved pin's note text. The rect, id and number are unchanged:
    /// this story's "edited" pins mean the note text, not the region (moving
    /// or resizing a saved region is not asked for, and not modeled here).
    mutating func updateCommentText(id: String, text: String) {
        guard let index = comments.firstIndex(where: { $0.id == id }) else { return }
        let existing = comments[index]
        comments[index] = existing.with(n: existing.n, text: text)
    }

    /// Every saved comment across the case, in creation (`n`) order: the flat
    /// list the Comments column shows.
    var orderedComments: [Comment] { comments.sorted { $0.n < $1.n } }

    /// The comments the live page draws: those whose capture was taken on
    /// `revision`, in number order. Older revisions' captures stay in the model
    /// but never show on a newer revision's page (HAIL-75).
    func comments(onRevision revision: Int) -> [Comment] {
        let ids = Set(captures.filter { $0.revision == revision }.map(\.id))
        return orderedComments.filter { ids.contains($0.captureId) }
    }

    /// HAIL-103: the view a comment was made on (its capture's).
    func view(of comment: Comment) -> PageView? {
        captures.first { $0.id == comment.captureId }?.view
    }

    /// Deletes a comment and renumbers the rest of the case 1..n in their
    /// original creation order (HAIL-75: no gaps).
    mutating func deleteComment(id: String) {
        guard let removedIndex = comments.firstIndex(where: { $0.id == id }) else { return }
        elementContexts[comments[removedIndex].id] = nil
        comments.remove(at: removedIndex)
        renumber()
    }

    private mutating func renumber() {
        let orderedIndices = comments.indices.sorted { comments[$0].n < comments[$1].n }
        for (position, index) in orderedIndices.enumerated() {
            let existing = comments[index]
            comments[index] = existing.with(n: position + 1, text: existing.text)
        }
    }
}
