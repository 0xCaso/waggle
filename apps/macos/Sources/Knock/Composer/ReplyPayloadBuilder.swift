import AppKit

/// Builds the wire `comments`/`captures` a `reply.submit` call sends
/// (docs/protocol-mvp.md "Socket RPC"): only captures that have at least one
/// comment are included and rendered, matching the daemon's own reply
/// payload rule ("one image block per capture that has comments") - a
/// capture nobody commented on has nothing to say to the agent.
///
/// The human reviews the full-resolution image on the stage; what goes on
/// the wire is `NSImage.captureWireData()` (JPEG, long edge capped). Two
/// full Retina PNGs per capture made one 4-comment reply 17.8 MB, and the
/// send timed out (operator, 4 Oct).
@MainActor
enum ReplyPayloadBuilder {
    /// The `item_answers` of a Decide reply on a request with exactly one item (WAG-315): the option id
    /// picked, or the ids ticked on a pick-several item. The old `choice` and `choices` go with it. `nil` for
    /// a payload with no items, for several items (the answers bar builds those) and for a reply item,
    /// whose message is the answer.
    static func itemAnswers(for request: Case, choice: String?, choices: [String]?) -> [ItemAnswer]? {
        guard request.items.count == 1, let item = request.items.first, item.select != .reply else { return nil }
        if item.select == .many, let choices, !choices.isEmpty {
            return [ItemAnswer(itemId: item.id, choices: choices, confirmed: true)]
        }
        // Only a choice the person made reaches here (WAG-328), so it is marked confirmed.
        if let choice { return [ItemAnswer(itemId: item.id, choice: choice, confirmed: true)] }
        return nil
    }

    /// - Parameter screenLabel: A `screenshots` case's own per-image label
    ///   ("Screen N[ · caption]", `CommentsSessionStore.screenLabel(for:)`),
    ///   carried onto the wire `Capture.note` field (HAIL-40) so the daemon's
    ///   reply text reads "Comments on Screen N · caption" instead of
    ///   "Comments on revision N, capture M". `nil` for every other kind -
    ///   the pre-HAIL-40 behaviour of sending no note.
    static func build(
        model: CommentsModel, imagesByCaptureId: [String: NSImage],
        screenLabel: (CaptureRecord) -> String? = { _ in nil }
    ) -> (comments: [Comment], captures: [Capture]) {
        let captureIdsWithComments = Set(model.comments.map(\.captureId))
        let captures: [Capture] = model.captures
            .filter { captureIdsWithComments.contains($0.id) }
            .compactMap { record in
                guard let image = imagesByCaptureId[record.id], let rawData = image.captureWireData() else { return nil }
                let commentsOnCapture = model.comments(on: record.id)
                let annotatedImage = AnnotatedCaptureRenderer.render(image: image, comments: commentsOnCapture)
                let annotatedData = annotatedImage.captureWireData() ?? rawData
                return Capture(
                    id: record.id,
                    revision: record.revision,
                    pngBase64: rawData.base64EncodedString(),
                    annotatedPngBase64: annotatedData.base64EncodedString(),
                    takenAt: KnockDateFormat.string(from: record.takenAt),
                    note: screenLabel(record)
                )
            }
        // Grouped by capture, so a multi-capture reply reads in the order its
        // captures were taken. `n` is case-wide since HAIL-75 (unique across
        // the reply, matching the number drawn on each capture's image), so
        // within a capture the numbers still ascend but may skip.
        let captureOrder = Dictionary(uniqueKeysWithValues: model.captures.map { ($0.id, $0.n) })
        let comments = model.comments.map { comment -> Comment in
            // HAIL-240: the page element goes inside the text, so the wire shape stays as it is.
            guard let element = model.elementContexts[comment.id], !comment.isText else { return comment.withRect(comment.rect.clamped()) }
            return Comment(id: comment.id, captureId: comment.captureId, n: comment.n, rect: comment.rect.clamped(), text: element.wireText(note: comment.text))
        }.sorted { lhs, rhs in
            let lhsCapture = captureOrder[lhs.captureId] ?? 0
            let rhsCapture = captureOrder[rhs.captureId] ?? 0
            return lhsCapture == rhsCapture ? lhs.n < rhs.n : lhsCapture < rhsCapture
        }
        return (comments, captures)
    }
}
