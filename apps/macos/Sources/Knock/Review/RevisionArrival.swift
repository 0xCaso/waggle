import Foundation

/// Non-nil when a case's artifact was just returned with a new revision
/// (docs/design/mvp-values.md §M9 `EDMW5`, docs/stories/KNOCK-14.md): more
/// than one revision exists and the case is back in `needs_you` - the only
/// way a review case cycles back there after its first revision is
/// `knock_update` adding one (docs/protocol-mvp.md "`knock_update`": "Adds an
/// agent message and, when an artifact is given, a new revision. The case
/// returns to `needs_you`").
struct RevisionArrival: Equatable {
    let latestRevision: Int
    let priorRevision: Int
    /// Comments saved on the prior revision's captures (docs/design/
    /// mvp-values.md §M9 `E0OSB`: "2 comments on v2").
    let priorCommentCount: Int
    /// The agent's own message from the update that brought this revision
    /// (§M9 Thread), the most recent agent message when there is more than
    /// one. `nil` on the (untested-for-in-the-mock, but possible) case where
    /// `knock_update` added a revision with an empty message.
    let agentMessage: Message?
}

extension CaseDetail {
    var revisionArrival: RevisionArrival? {
        guard self.case.status == .needsYou else { return nil }
        // HAIL-168: a revision the person made is not an arrival from the agent.
        let orderedRevisions = revisions.filter { $0.author == .agent }.sorted { $0.n < $1.n }
        guard let latest = orderedRevisions.last else { return nil }

        let prior: Revision?
        if orderedRevisions.count > 1 {
            prior = orderedRevisions[orderedRevisions.count - 2]
        } else if replies.contains(where: { $0.intent == .moreDetail || $0.intent == .discuss }) {
            // HAIL-33: a detail request's first knock_update answer has no
            // prior revision to compare against (the ask itself may have
            // carried no artifact at all), but the agent's message should
            // still show above the options the same way it does for a
            // returning v2 - there is nothing to link back to, so
            // priorCommentCount stays 0 and the "view v<n-1>" link never
            // shows for this single-revision case.
            prior = nil
        } else {
            return nil
        }

        let priorCommentCount: Int = {
            guard let prior else { return 0 }
            let priorCaptureIds = Set(
                replies.flatMap(\.captures).filter { $0.revision == prior.n }.map(\.id)
            )
            return comments.filter { $0.anchor.map { $0.revision == prior.n } ?? priorCaptureIds.contains($0.captureId) }.count
        }()

        let agentMessage = messages
            .filter { $0.role == .agent }
            .max { ($0.createdAtDate ?? .distantPast) < ($1.createdAtDate ?? .distantPast) }

        return RevisionArrival(
            latestRevision: latest.n,
            priorRevision: prior?.n ?? latest.n,
            priorCommentCount: priorCommentCount,
            agentMessage: agentMessage
        )
    }
}
