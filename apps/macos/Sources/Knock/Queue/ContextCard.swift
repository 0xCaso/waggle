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

/// The context card (HAIL-107, prototype #D1): one 28 pt row per item, a detail on a rail when a
/// row opens, and the agent's newest update under a hairline. Rows follow the "Tool Chips" pattern
/// of Beautiful UI (MIT, beautifului.dev).
struct ContextCardView: View {
    let model: ContextCardModel
    var onOpenCase: (String) -> Void = { _ in }
    /// Opens the version before the latest ("See v1"); nil hides the link.
    var onSeeVersion: (() -> Void)? = nil
    /// Row kinds open at the start: `KNOCK_EVIDENCE_CONTEXT_OPEN=earlier,replied` (evidence only).
    @State private var openIds: Set<String>
    /// The same env kinds, kept so a row that appears after the first render (session context loads late) opens too.
    private let evidenceOpenKinds: Set<String>
    @State private var isHidden = false
    @State private var showsAllOfUpdate = false
    @State private var updateFullHeight: CGFloat = 0
    @State private var updateShownHeight: CGFloat = 0

    init(
        model: ContextCardModel, onOpenCase: @escaping (String) -> Void = { _ in }, onSeeVersion: (() -> Void)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.model = model
        self.onOpenCase = onOpenCase
        self.onSeeVersion = onSeeVersion
        let kinds = Set((environment["KNOCK_EVIDENCE_CONTEXT_OPEN"] ?? "").split(separator: ",").map(String.init))
        evidenceOpenKinds = kinds
        _openIds = State(initialValue: Set(model.rows.filter { kinds.contains($0.kind.rawValue) }.map(\.id)))
    }

    var body: some View {
        if !model.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                header
                if !isHidden {
                    ForEach(model.rows) { row in
                        ContextRowView(
                            row: row, isOpen: openIds.contains(row.id) || evidenceOpenKinds.contains(row.kind.rawValue), onOpenCase: onOpenCase,
                            onToggle: { toggle(row.id) })
                    }
                }
                if let update = model.update { updateView(update) }
            }
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 9, trailing: 10))
            .boundedIdealWidth()
            .paneCardSurface()
        }
    }

    private func toggle(_ id: String) {
        if openIds.contains(id) { openIds.remove(id) } else { openIds.insert(id) }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(model.title)
                .knockTextStyle(Theme.Typography.caption11_5w400)
                .foregroundColor(Theme.Colors.ink3)
            Spacer(minLength: 8)
            if !model.rows.isEmpty {
                Button(isHidden ? "Show" : "Hide") { isHidden.toggle() }
                    .buttonStyle(.plain).pointerCursor()
                    .knockTextStyle(Theme.Typography.caption11_5w400)
                    .foregroundColor(Theme.Colors.ink3)
            }
        }
        .padding(.bottom, 3)
    }

    // MARK: Newest update

    private func updateView(_ update: ContextCardModel.Update) -> some View {
        let plain = AgentMarkdown.plainText(update.message).replacingOccurrences(of: "\n", with: " ")
        let truncated = updateFullHeight > updateShownHeight + 1
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.Colors.ds)
                    .frame(width: 16)
                Text("\(update.runtime) updated it")
                    .knockTextStyle(Theme.Typography.rowLabel12_5w500)
                    .foregroundColor(Theme.Colors.ds)
                if let label = update.revisionLabel {
                    Text(label)
                        .knockTextStyle(Theme.Typography.monoMetaRow10_5w400)
                        .foregroundColor(Theme.Colors.ds)
                }
                Spacer(minLength: 8)
                Text(update.time)
                    .knockTextStyle(Theme.Typography.monoMetaRow10_5w400)
                    .foregroundColor(Theme.Colors.ink3)
            }
            if plain.isEmpty {
                EmptyView()
            } else if showsAllOfUpdate {
                AgentMarkdownText(text: update.message, style: Theme.Typography.body12_5w400)
            } else {
                Text(plain)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.ink)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { updateShownHeight = $0 }
                    .background(
                        Text(plain).knockTextStyle(Theme.Typography.body12_5w400)
                            .fixedSize(horizontal: false, vertical: true).hidden()
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { updateFullHeight = $0 }
                    )
            }
            HStack(spacing: 12) {
                if truncated || showsAllOfUpdate {
                    Button(showsAllOfUpdate ? "Show less" : "Read all") { showsAllOfUpdate.toggle() }
                        .buttonStyle(.plain).pointerCursor().underline()
                }
                if let prior = update.priorVersion, let onSeeVersion {
                    Button("See v\(prior)", action: onSeeVersion).buttonStyle(.plain).pointerCursor().underline()
                }
            }
            .knockTextStyle(Theme.Typography.caption11_5w400)
            .foregroundColor(Theme.Colors.ink2)
        }
        .padding(.top, 8)
        .overlay(Rectangle().fill(Theme.Colors.line).frame(height: 1), alignment: .top)
        .padding(.top, 6)
    }
}

/// One 28 pt row: icon, label, a one-line chip, a mono time, and a › that shows on hover.
private struct ContextRowView: View {
    let row: ContextCardModel.Row
    let isOpen: Bool
    let onOpenCase: (String) -> Void
    let onToggle: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    icon.frame(width: 16, height: 16)
                    Text(row.label)
                        .knockTextStyle(Theme.Typography.rowLabel12_5w500)
                        .foregroundColor(Theme.Colors.ink)
                        .lineLimit(1)
                        .fixedSize()
                        .layoutPriority(1)
                    Text(row.chip)
                        .knockTextStyle(Theme.Typography.caption11_5w400)
                        .foregroundColor(Theme.Colors.ink2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 7)
                        .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22, alignment: .leading)
                        .background(Theme.Colors.list)
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.Colors.line, lineWidth: 1))
                    Text(row.time)
                        .knockTextStyle(Theme.Typography.monoMetaRow10_5w400)
                        .foregroundColor(Theme.Colors.ink3)
                        .frame(width: 34, alignment: .trailing)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.Colors.ink3)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .opacity(hovered || isOpen || CopyHover.forced ? 1 : 0)
                        .frame(width: 10)
                }
                .padding(.horizontal, 4)
                .frame(height: 28)
                .background(hovered ? Theme.Colors.hover : Color.clear)
                .cornerRadius(8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .padding(.horizontal, -4)
            .onHover { hovered = $0 }
            .accessibilityLabel("\(row.label): \(row.chip)")
            .accessibilityHint(isOpen ? "Closes the detail" : "Opens the detail")
            if isOpen { detail }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch row.kind {
        case .session:
            if let status = row.status {
                PixelStatusGrid(pattern: status.pattern, color: status.color, cell: 3)
            } else {
                Image(systemName: "square.grid.3x3.fill").font(.system(size: 10)).foregroundColor(Theme.Colors.accent)
            }
        case .earlier: symbol("clock", Theme.Colors.ink3)
        case .asked: symbol("bubble.left", Theme.Colors.ink3)
        case .replied: symbol("arrowshape.turn.up.left", Theme.Colors.ink3)
        case .updated: symbol("arrow.triangle.2.circlepath", Theme.Colors.ds)
        }
    }

    private func symbol(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).font(.system(size: 11)).foregroundColor(color)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(row.details) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let time = item.time {
                            Text(time)
                                .knockTextStyle(Theme.Typography.monoMetaRow10_5w400)
                                .foregroundColor(Theme.Colors.ink3)
                        }
                        if let caseId = item.caseId {
                            Button(action: { onOpenCase(caseId) }) {
                                Text(item.text).knockTextStyle(Theme.Typography.body12_5w400)
                                    .foregroundColor(Theme.Colors.ink)
                                    .multilineTextAlignment(.leading)
                            }
                            .buttonStyle(.plain).pointerCursor()
                            .help("Open this decision")
                        } else {
                            AgentMarkdownText(text: item.text, style: Theme.Typography.body12_5w400)
                        }
                    }
                    if let caption = item.caption {
                        Text(caption)
                            .knockTextStyle(Theme.Typography.threadTimestamp11_5w400)
                            .foregroundColor(Theme.Colors.ink3)
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 0))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().fill(Theme.Colors.line2).frame(width: 1), alignment: .leading)
        .padding(EdgeInsets(top: 2, leading: 8, bottom: 6, trailing: 0))
    }
}
