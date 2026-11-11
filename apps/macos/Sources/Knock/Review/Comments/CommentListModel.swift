import Foundation

/// WAG-307: what an artifact surface shows right now, so the one comment list can tell the comments
/// that have a pin on screen from the ones whose page state is gone. The full size viewer and the
/// case page's artifact box each build one from what they show.
struct CommentViewContext: Equatable {
    /// The kind on show. `nil` while it loads: every comment counts as on view then.
    var kind: ArtifactKind?
    var revision: Int?
    /// The view a live page is on now (`WebViewCaptureController.pageView`).
    var pageView: PageView?
    /// The still on show: a screen of a screenshots set, or the screenshot itself. `nil` for a live
    /// page, a write-up, and a set view that shows every screen.
    var shownCaptureId: String?

    var isLive: Bool { kind == .htmlBundle || kind == .diagram }
    var isStills: Bool { kind == .screenshot || kind == .screenshots }

    static let unknown = CommentViewContext()
}

/// Where Show takes the operator to see a comment that is not on view.
enum CommentShowTarget: Equatable {
    /// Another revision of the artifact (or another artifact tab).
    case revision(Int)
    /// Another screen or capture of the same revision.
    case capture(String)
    /// Another state of the same live page.
    case pageView(PageView?)
}

enum CommentPlacement: Equatable {
    case onView
    case otherView(CommentShowTarget)
}

/// Pin or no pin, per anchor kind. One rule for the list in full size and on the case page.
enum CommentVisibility {
    static func placement(of comment: Comment, model: CommentsModel, context: CommentViewContext) -> CommentPlacement {
        guard let kind = context.kind, let revision = context.revision else { return .onView }
        if let anchor = comment.anchor {
            // A comment on the text of a write-up: it has a pin only on that revision of a write-up.
            if kind == .markdown && anchor.revision == revision { return .onView }
            return .otherView(.revision(anchor.revision))
        }
        guard let capture = model.captures.first(where: { $0.id == comment.captureId }) else { return .onView }
        if capture.revision != revision { return .otherView(.revision(capture.revision)) }
        if context.isLive {
            return PageView.shows(comment: capture.view, current: context.pageView) ? .onView : .otherView(.pageView(capture.view))
        }
        if context.isStills {
            guard let shown = context.shownCaptureId, shown != capture.id else { return .onView }
            return .otherView(.capture(capture.id))
        }
        // A capture comment, but a write-up on show.
        return .otherView(.revision(capture.revision))
    }
}

/// The plain line that says what an anchor is. Same words in the list on every surface.
enum CommentAnchorLabel {
    static func make(comment: Comment, model: CommentsModel, isScreenshotsCase: Bool) -> String {
        if comment.isText { return "On the span" }
        // WAG-357: the part of the request, in plain words ("On the title").
        if let ask = comment.askAnchor { return ask.part.onWords }
        guard let capture = model.captures.first(where: { $0.id == comment.captureId }) else { return "region" }
        if isScreenshotsCase { return "Screen \(capture.n) · region" }
        return model.captures.count > 1 ? "Capture \(capture.n) · region" : "region"
    }
}

enum CommentRowState: String, Equatable {
    case saved, sent

    var label: String { rawValue }
}

struct CommentRow: Identifiable, Equatable {
    let comment: Comment
    let anchorLabel: String
    let state: CommentRowState
    let placement: CommentPlacement

    var id: String { comment.id }
    var number: Int { comment.n }
    var text: String { comment.text }
    var isOffView: Bool { placement != .onView }
}

/// The rows of the one comment list: the comments with a pin first, then "On other views".
struct CommentListModel: Equatable {
    static let otherViewsTitle = "On other views"
    /// True in the pane and in full size: both put a Comment switch on the artifact (C key in full size).
    static let emptyLine = "No comments yet. Choose Comment on the artifact, then click the page or select text."
    /// A request with no artifact: its own words are what you can comment on (WAG-357).
    static let textAskEmptyLine = "No comments yet. Select words in the request to comment on them."

    let onView: [CommentRow]
    let otherViews: [CommentRow]

    var isEmpty: Bool { onView.isEmpty && otherViews.isEmpty }
    var rows: [CommentRow] { onView + otherViews }

    static func make(model: CommentsModel, context: CommentViewContext, isScreenshotsCase: Bool) -> CommentListModel {
        var onView: [CommentRow] = []
        var other: [CommentRow] = []
        for comment in model.orderedComments {
            let placement = CommentVisibility.placement(of: comment, model: model, context: context)
            let row = CommentRow(
                comment: comment,
                anchorLabel: CommentAnchorLabel.make(comment: comment, model: model, isScreenshotsCase: isScreenshotsCase),
                state: .saved, placement: placement)
            if row.isOffView { other.append(row) } else { onView.append(row) }
        }
        return CommentListModel(onView: onView, otherViews: other)
    }
}

/// One step of what Show does for a comment. The host runs the steps in order.
enum CommentShowStep: Equatable {
    case switchRevision(Int)
    case showCapture(String)
    case setHash(String)
    /// Look for the element the pin points at on the page, then say so when it is not there.
    case findElement
    /// Highlight the comment and bring its pin into view.
    case reveal
}

enum CommentShowPlan {
    /// The steps for one comment. `canShowStill` is true where a capture can open as a still (full
    /// size); the case page's box has no still to open, so a state it cannot reach is said, not faked.
    static func steps(for comment: Comment, model: CommentsModel, context: CommentViewContext, canShowStill: Bool) -> [CommentShowStep] {
        guard case .otherView(let target) = CommentVisibility.placement(of: comment, model: model, context: context) else {
            return [.reveal]
        }
        let capture = model.captures.first { $0.id == comment.captureId }
        let revision = comment.anchor?.revision ?? capture?.revision
        var switchStep: [CommentShowStep] = []
        if let revision, revision != context.revision { switchStep = [.switchRevision(revision)] }
        // A comment on the text of a write-up: its revision, then its highlight.
        guard !comment.isText, let capture else { return switchStep + [.reveal] }
        if case .capture(let id) = target { return [.showCapture(id), .reveal] }
        // A live capture has the page's position and view; a restored one is a still.
        guard capture.page != nil || capture.view != nil else {
            return (canShowStill ? [] : switchStep) + [.showCapture(capture.id), .reveal]
        }
        // An earlier revision's page is gone: its capture is the still to look at.
        if canShowStill && !switchStep.isEmpty { return [.showCapture(capture.id)] }
        if let hash = capture.view?.hash, !hash.isEmpty { return switchStep + [.setHash(hash), .findElement, .reveal] }
        // No address to go to: a still where one can open, else look, and say when it is not there.
        if canShowStill { return [.showCapture(capture.id)] }
        return switchStep + [.findElement, .reveal]
    }

    /// True when the element a pin was on is on the page now: the same role and text. A pin with no
    /// stored element has nothing to compare, so the page gets the benefit of the doubt.
    static func elementFound(stored: PageElementContext?, found: PageElementContext?) -> Bool {
        guard let stored else { return true }
        guard let found else { return false }
        return stored.role == found.role && stored.text == found.text
    }

    /// "This part of the prototype is not on screen now. It was on: the button "Pay now"".
    static func notOnScreenLine(element: PageElementContext?) -> String {
        let place: String
        if let element {
            place = element.text.isEmpty ? "the \(element.role)" : "the \(element.role) \"\(element.text)\""
        } else {
            place = "a part of the page I can't name"
        }
        return "This part of the prototype is not on screen now. It was on: \(place)"
    }
}

/// What a surface lets Show do. Each surface fills in the ones it can.
@MainActor
struct CommentShowActions {
    var switchRevision: (Int) -> Void = { _ in }
    var showCapture: (String) -> Void = { _ in }
    var setHash: (String) async -> Void = { _ in }
    /// True when the element the pin points at is on the page now.
    var findElement: (Comment) async -> Bool = { _ in true }
    var reveal: (Comment) -> Void = { _ in }
    var canShowStill = true
}

extension CommentShowPlan {
    /// Runs the steps. Returns the one plain line to show when the part cannot be found, else `nil`.
    @MainActor
    static func run(
        comment: Comment, model: CommentsModel, context: CommentViewContext, actions: CommentShowActions
    ) async -> String? {
        let steps = steps(for: comment, model: model, context: context, canShowStill: actions.canShowStill)
        let line = notOnScreenLine(element: model.elementContexts[comment.id])
        for step in steps {
            switch step {
            case .switchRevision(let revision): actions.switchRevision(revision)
            case .showCapture(let id): actions.showCapture(id)
            case .setHash(let hash): await actions.setHash(hash)
            case .findElement:
                if await actions.findElement(comment) == false { return line }
            case .reveal: actions.reveal(comment)
            }
        }
        return nil
    }
}
