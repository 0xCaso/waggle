import Foundation

/// One step on the ask's thread (HAIL-68): what the agent asked, what you
/// replied, what the agent did next. Built from the case detail's `messages`,
/// `replies` and `revisions`, so it needs no field of its own.
enum ThreadStep: Equatable, Sendable {
    struct Asked: Equatable, Sendable {
        let need: String
        /// "v1 · Prototype", or "Prototype" with no revision; nil with no artifact.
        let meta: String?
        let at: Date
    }

    struct PickedUp: Equatable, Sendable {
        let runtime: String
        let at: Date
        /// From pickup to the agent's next update; nil while it is still working.
        let worked: TimeInterval?
    }

    struct Replied: Equatable, Sendable {
        /// Choice and message, "Changes needed · the resend link".
        let summary: String
        /// "2 comments on v1"; nil with none.
        let meta: String?
        let at: Date
        let pickedUp: PickedUp?
    }

    struct Updated: Equatable, Sendable {
        struct NewRevision: Equatable, Sendable {
            let n: Int
            let isLatest: Bool
            /// The revision before it, for "Open review · see v<N-1>".
            let prior: Int?
        }

        let message: String
        let revision: NewRevision?
        let at: Date
    }

    case asked(Asked)
    case replied(Replied)
    case updated(Updated)

    var at: Date {
        switch self {
        case .asked(let step): step.at
        case .replied(let step): step.at
        case .updated(let step): step.at
        }
    }
}

struct ThreadModel: Equatable, Sendable {
    let steps: [ThreadStep]
    /// "Claude Code": who asked and who updated.
    let runtimeName: String
    /// The ask has an html bundle or screenshots, so "no new revision" can be true (HAIL-115).
    /// A text-only ask has no revisions, so the update step says nothing about one.
    var hasArtifact: Bool = true

    /// Steps shown while folded: your latest reply onward.
    var foldedSteps: [ThreadStep] {
        guard let last = steps.lastIndex(where: { if case .replied = $0 { true } else { false } }) else { return steps }
        return Array(steps[last...])
    }

    func visibleSteps(expanded: Bool) -> [ThreadStep] { expanded ? steps : foldedSteps }

    /// True when folding hides at least one step, so "Show all" has a use.
    var canFold: Bool { foldedSteps.count < steps.count }

    /// "3 steps" / "1 step".
    var countLabel: String { "\(steps.count) step\(steps.count == 1 ? "" : "s")" }

}

extension CaseDetail {
    /// nil until the ask has a reply to show.
    func threadModel(artifactKind: ArtifactKind? = nil) -> ThreadModel? {
        let liveReplies = replies
            .filter { $0.state != .superseded }
            .compactMap { reply in KnockDateFormat.date(from: reply.createdAt).map { (reply, $0) } }
            .sorted { $0.1 < $1.1 }
        guard let firstReplyAt = liveReplies.first?.1 else { return nil }

        let c = self.case
        let runtime = c.runtimeLabel
        let orderedRevisions = revisions.sorted { $0.n < $1.n }
        let latestRevision = orderedRevisions.last?.n
        let revisionTimes = orderedRevisions.compactMap { rev in
            KnockDateFormat.date(from: rev.createdAt).map { (rev.n, $0) }
        }

        // An agent message before your first reply is not an update.
        let updates = messages
            .filter { $0.role == .agent }
            .compactMap { message in KnockDateFormat.date(from: message.createdAt).map { (message, $0) } }
            .filter { $0.1 > firstReplyAt }
            .sorted { $0.1 < $1.1 }

        var steps: [ThreadStep] = []
        let askedAt = c.createdAtDate ?? firstReplyAt
        var askedMeta: String?
        if let first = orderedRevisions.first {
            askedMeta = ["v\(first.n)", artifactKind?.indicatorLabel].compactMap { $0 }.joined(separator: " · ")
        } else if let artifactKind {
            askedMeta = artifactKind.indicatorLabel
        }
        steps.append(.asked(.init(
            need: c.need.split(whereSeparator: \.isWhitespace).joined(separator: " "), meta: askedMeta, at: askedAt)))

        // A revision belongs to the update that brought it: made after the step
        // before and no later than the update (the daemon writes both in one go).
        func revisionForUpdate(after previousAt: Date, until updateAt: Date) -> ThreadStep.Updated.NewRevision? {
            guard let made = revisionTimes.last(where: { $0.1 > previousAt && $0.1 <= updateAt.addingTimeInterval(5) }) else {
                return nil
            }
            let index = orderedRevisions.firstIndex { $0.n == made.0 }
            let prior = index.flatMap { $0 > 0 ? orderedRevisions[$0 - 1].n : nil }
            return .init(n: made.0, isLatest: made.0 == latestRevision, prior: prior)
        }

        for (index, (reply, replyAt)) in liveReplies.enumerated() {
            let roundEnd = index + 1 < liveReplies.count ? liveReplies[index + 1].1 : .distantFuture
            let roundUpdates = updates.filter { $0.1 > replyAt && $0.1 <= roundEnd }
            let pickedAt = reply.deliveredAt.flatMap(KnockDateFormat.date(from:))
                ?? (index == liveReplies.count - 1 && reply.state == .delivered ? c.latestReplyDeliveredAtDate : nil)
            var pickedUp: ThreadStep.PickedUp?
            if let pickedAt {
                pickedUp = .init(runtime: runtime, at: pickedAt, worked: roundUpdates.first.map { max(0, $0.1.timeIntervalSince(pickedAt)) })
            }
            steps.append(.replied(.init(
                summary: replySummary(reply), meta: commentsMeta(reply), at: replyAt, pickedUp: pickedUp)))

            for (offset, (message, messageAt)) in roundUpdates.enumerated() {
                let previousAt = offset == 0 ? replyAt : roundUpdates[offset - 1].1
                let revision = revisionForUpdate(after: previousAt, until: messageAt)
                steps.append(.updated(.init(
                    message: message.text.trimmingCharacters(in: .whitespacesAndNewlines), revision: revision, at: messageAt)))
            }
        }
        let hasArtifact: Bool
        switch artifactKind {
        case .htmlBundle?, .screenshot?, .screenshots?, .diagram?: hasArtifact = true
        case .markdown?: hasArtifact = false
        case nil: hasArtifact = !orderedRevisions.isEmpty
        }
        return ThreadModel(steps: steps, runtimeName: runtime, hasArtifact: hasArtifact)
    }

    /// The thread's last line: your turn, or the agent's status while it works.
    func threadTurn(
        _ model: ThreadModel, delivery: DeliveryState? = nil, settled: AnswerGrouping.Settled? = nil
    ) -> ThreadTurn {
        let c = self.case
        // An answered ask (HAIL-104) ends the thread on a settled line: no live status, no timer.
        if let settled {
            return ThreadTurn(
                status: .closed, label: AgentStatusCopy.settledLine(pickedUpAt: settled.pickedUpAt), since: nil)
        }
        let status = AgentStatus.forCase(c, deliveryStatus: delivery)
        if status == .needsYou {
            var newRevision: Int?
            if case .updated(let update)? = model.steps.last { newRevision = update.revision?.n }
            return ThreadTurn(
                status: status,
                label: "Your turn: " + ThreadCopy.yourTurn(kind: c.kind, newRevision: newRevision),
                since: model.steps.last?.at)
        }
        return ThreadTurn(
            status: status,
            label: AgentStatusCopy.headline(status: status, runtime: model.runtimeName, item: c) ?? status.label,
            since: AgentStatus.timerStart(c, status: status, deliveryStatus: delivery))
    }

    /// "Changes needed · the resend link and the spacing". A detail request is a short lead and the
    /// full question under it, as its own paragraph, so a long question wraps and the hover Copy
    /// pill sits over the short lead line, not over the question. A detail request that named a
    /// format (HAIL-139) reads "Asked for more detail · as a diagram" as its lead.
    private func replySummary(_ reply: Reply) -> String {
        let message = reply.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if reply.intent == .moreDetail {
            return MoreDetailCopy.thread(format: reply.format, message: message)
        }
        if reply.intent == .discuss {
            let titles = { (ids: [String]?) in
                (ids ?? []).map { id in self.case.options.first(where: { $0.id == id }).map(\.displayTitle) ?? id }
            }
            return DiscussCopy.banner(leaning: titles(reply.leaning), ruledOut: titles(reply.ruledOut), message: message)
        }
        var parts: [String] = []
        if let choices = reply.choices, !choices.isEmpty {
            parts.append(choices.map { id in
                self.case.options.first(where: { $0.id == id }).map(\.displayTitle) ?? id
            }.joined(separator: ", "))
        }
        if let choice = reply.choice {
            let label = self.case.options.first(where: { $0.id == choice })
                .map(\.displayTitle) ?? choice
            parts.append(label)
        }
        if !message.isEmpty { parts.append(message) }
        return parts.isEmpty ? "Replied with comments" : parts.joined(separator: " · ")
    }

    /// "2 comments on v1".
    private func commentsMeta(_ reply: Reply) -> String? {
        guard !reply.comments.isEmpty else { return nil }
        let n = reply.comments.count
        let revisionByCapture = Dictionary(reply.captures.map { ($0.id, $0.revision) }, uniquingKeysWith: { a, _ in a })
        let revision = reply.comments.compactMap { $0.anchor?.revision ?? revisionByCapture[$0.captureId] }.max()
        return "\(n) comment\(n == 1 ? "" : "s")" + (revision.map { " on v\($0)" } ?? "")
    }
}

/// The words of a "more detail" request, shared by the thread and the delivery banner so they
/// cannot drift (HAIL-147). Pure, so they are unit-tested.
enum MoreDetailCopy {
    /// "Asked for more detail" or "Asked for more detail · as a diagram".
    static func lead(format: ReplyFormat?) -> String {
        format.map { "Asked for more detail · \($0.threadLabel)" } ?? "Asked for more detail"
    }

    /// The thread line: the lead, then the request as its own paragraph when there is one.
    static func thread(format: ReplyFormat?, message: String?) -> String {
        let text = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? lead(format: format) : "\(lead(format: format))\n\n\(text)"
    }

    /// The banner bubble's text, one line: the lead, then the request after a dot.
    static func banner(format: ReplyFormat?, message: String?) -> String {
        thread(format: format, message: message).replacingOccurrences(of: "\n\n", with: " · ")
    }
}

/// The words of the thread's own lines. Pure, so they are unit-tested.
enum ThreadCopy {
    /// "worked 8m", "worked 45s".
    static func worked(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        if seconds < 60 { return "worked \(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "worked \(minutes)m" }
        let rest = minutes % 60
        return "worked \(minutes / 60)h" + (rest == 0 ? "" : " \(rest)m")
    }

    /// "HH:mm" for a step's time.
    static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// The update step's note: the new version, or plainly that the update brought none (HAIL-114).
    /// Nil for an ask with no artifact: there is no revision to talk about (HAIL-115).
    static func updatedMeta(revision: ThreadStep.Updated.NewRevision?, hasArtifact: Bool = true) -> String? {
        if let revision { return "v\(revision.n) is new" }
        return hasArtifact ? "no new revision" : nil
    }

    /// What you should do now, after "Your turn: ". `newRevision` is the version
    /// the agent's last update brought, if any.
    static func yourTurn(kind: Case.Kind, newRevision: Int?) -> String {
        if kind == .review {
            if let newRevision { return "approve v\(newRevision) or ask for changes" }
            return "approve it or ask for changes"
        }
        return "pick an option or reply"
    }
}
