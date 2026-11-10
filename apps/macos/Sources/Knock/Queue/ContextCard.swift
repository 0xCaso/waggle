import SwiftUI

/// What the context card shows (HAIL-107): the session line, the session's earlier asks, each
/// thread step once, and the agent's newest update at the bottom. It replaces the THREAD card,
/// the session block and "Earlier in this session". Pure, so the rows are unit-tested.
struct ContextCardModel: Equatable {
    struct Detail: Equatable, Identifiable {
        let id: Int
        let time: String?
        let text: String
        /// An earlier ask this line opens on tap.
        let caseId: String?
        /// "Picked up by Claude Code 13:10 · worked 14s" under a reply.
        let caption: String?
    }

    struct Row: Equatable, Identifiable {
        enum Kind: String, Equatable { case session, earlier, asked, replied, updated }
        let id: String
        let kind: Kind
        let label: String
        /// The one-line text in the chip.
        let chip: String
        /// A mono time: "13:10", or "1h" for the session.
        let time: String
        let details: [Detail]
        /// The session line's status, for its pixel icon.
        var status: AgentStatus? = nil
    }

    struct Update: Equatable {
        let runtime: String
        let message: String
        let time: String
        /// "v2 is new".
        let revisionLabel: String?
        /// The version before a latest revision, for "See v1".
        let priorVersion: Int?
    }

    /// "Context · 3rd ask".
    let title: String
    let rows: [Row]
    let update: Update?

    var isEmpty: Bool { rows.isEmpty && update == nil }

    static func make(block: SessionContextBlock?, thread: ThreadModel?, heading: RoundHeading? = nil) -> ContextCardModel {
        var rows: [Row] = []
        if let line = block?.line {
            rows.append(Row(
                id: "session", kind: .session, label: "This session", chip: line.summary, time: line.startedAgo ?? "",
                details: [Detail(id: 0, time: nil, text: line.summary + " " + line.detail, caseId: nil, caption: line.doingNow)],
                status: line.status))
        }
        if let earlier = block?.earlier, !earlier.isEmpty {
            let asks = Set(earlier.map(\.caseId)).count
            rows.append(Row(
                id: "earlier", kind: .earlier, label: "\(asks) earlier request\(asks == 1 ? "" : "s")",
                chip: earlier.map { $0.text.replacingOccurrences(of: "Update: ", with: "") }.joined(separator: " · "),
                time: ThreadCopy.clock(earlier[0].at),
                details: earlier.enumerated().map {
                    Detail(id: $0.offset, time: ThreadCopy.clock($0.element.at), text: $0.element.text, caseId: $0.element.caseId, caption: nil)
                }))
        }
        var update: Update?
        if let thread {
            // The newest step stays at the bottom when it is the agent's update; every other step is a row.
            var steps = thread.steps
            if case .updated(let last)? = steps.last, !last.message.isEmpty {
                steps.removeLast()
                update = Update(
                    runtime: thread.runtimeName, message: heading?.cardMessage(last.message) ?? last.message, time: ThreadCopy.clock(last.at),
                    revisionLabel: last.revision.map { "v\($0.n) is new" },
                    priorVersion: last.revision.flatMap { $0.isLatest ? $0.prior : nil })
            }
            for (index, step) in steps.enumerated() { rows.append(row(step, index: index, runtime: thread.runtimeName)) }
        }
        let title = block?.askNumber.map { "Context · \(SessionContextBlock.ordinal($0)) request" } ?? "Context"
        return ContextCardModel(title: title, rows: rows, update: update)
    }

    private static func row(_ step: ThreadStep, index: Int, runtime: String) -> Row {
        let time = ThreadCopy.clock(step.at)
        switch step {
        case .asked(let asked):
            return Row(
                id: "asked-\(index)", kind: .asked, label: "Decision", chip: AgentMarkdown.singleLine(asked.need), time: time,
                details: [Detail(id: 0, time: nil, text: asked.need, caseId: nil, caption: asked.meta)])
        case .replied(let replied):
            var caption: String?
            if let picked = replied.pickedUp {
                caption = "Picked up by \(picked.runtime) " + ThreadCopy.clock(picked.at)
                    + (picked.worked.map { " · " + ThreadCopy.worked($0) } ?? "")
            }
            return Row(
                id: "replied-\(index)", kind: .replied, label: "You replied", chip: AgentMarkdown.singleLine(replied.summary),
                time: time,
                details: [Detail(id: 0, time: nil, text: replied.summary, caseId: nil, caption: [replied.meta, caption].compactMap { $0 }.joined(separator: " · ").nilIfEmpty)])
        case .updated(let updated):
            return Row(
                id: "updated-\(index)", kind: .updated, label: "Updated", chip: AgentMarkdown.singleLine(updated.message), time: time,
                details: [Detail(id: 0, time: nil, text: updated.message, caseId: nil, caption: updated.revision.map { "v\($0.n) is new" })])
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
