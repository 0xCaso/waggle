import SwiftUI

/// The four small stage chips under a plan row's title (HAIL-151): the current stage is dark, a
/// finished one carries a tick, the rest are quiet.
struct PlanChipTrackView: View {
    let stage: PlanStageName
    var body: some View {
        GeometryReader { proxy in
            track(form: PlanTrackLayout.form(width: proxy.size.width, style: .chips, stage: stage))
                .frame(width: proxy.size.width, alignment: .leading)
        }
        .frame(height: 18)
    }

    @ViewBuilder
    private func track(form: PlanTrackLayout.Form) -> some View {
        Group {
            switch form {
            case .full:
                HStack(spacing: 4) {
                    ForEach(PlanText.track(current: stage), id: \.name) { item in
                        chip(item.name, state: item.state)
                    }
                }
            case .circles:
                HStack(spacing: 4) {
                    ForEach(Array(PlanText.track(current: stage).enumerated()), id: \.offset) { index, item in
                        if item.state == .current {
                            HStack(spacing: 6) {
                                PlanTrackDot(index: index, state: item.state, size: 18)
                                Text(PlanText.title(item.name))
                                    .knockTextStyle(Theme.Typography.tagLabel10_5w500)
                                    .foregroundColor(Theme.Colors.ink)
                            }
                        } else {
                            PlanTrackDot(index: index, state: item.state, size: 18).help(PlanText.title(item.name))
                        }
                    }
                }
            case .line:
                PlanTrackLineView(stage: stage, font: Theme.Typography.tagLabel10_5w500)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    @ViewBuilder
    private func chip(_ name: PlanStageName, state: PlanText.TrackState) -> some View {
        HStack(spacing: 3) {
            if state == .done {
                Image(systemName: "checkmark").font(.system(size: 7.5, weight: .bold))
            }
            Text(PlanText.title(name)).knockTextStyle(Theme.Typography.tagLabel10_5w500)
        }
        .foregroundColor(chipForeground(state))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(chipFill(state))
        .clipShape(Capsule())
        .fixedSize()
    }

    private func chipForeground(_ state: PlanText.TrackState) -> Color {
        switch state {
        case .done: Theme.Colors.ok
        case .current: Theme.Colors.win
        case .upcoming: Theme.Colors.ink3
        }
    }

    private func chipFill(_ state: PlanText.TrackState) -> Color {
        switch state {
        case .done: Theme.Colors.okSoft
        case .current: Theme.Colors.ink
        case .upcoming: Theme.Colors.sel
        }
    }
}

/// The "Plan · round 3" chip that takes the artifact chip's place on a plan row.
struct PlanRoundChipView: View {
    let rounds: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "checklist")
                .font(.system(size: 10))
                .foregroundColor(Theme.Colors.ink3)
            Text(PlanText.roundChip(rounds: rounds))
                .knockTextStyle(Theme.Typography.keyHint10_5w400)
                .foregroundColor(Theme.Colors.ink3)
        }
    }
}

/// The stage track at the top of the right column: numbered circles joined by a line. A finished stage
/// is a green tick, the current one a dark circle.
struct PlanStageTrackView: View {
    let stage: PlanStageName
    var body: some View {
        GeometryReader { proxy in
            track(form: PlanTrackLayout.form(width: proxy.size.width, style: .numbered, stage: stage))
                .frame(width: proxy.size.width, alignment: .leading)
        }
        .frame(height: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stage: \(PlanText.title(stage))")
    }

    @ViewBuilder
    private func track(form: PlanTrackLayout.Form) -> some View {
        switch form {
        case .full: fullTrack
        case .circles: circlesTrack
        case .line: PlanTrackLineView(stage: stage, font: Theme.Typography.recommendLine12w400)
        }
    }

    private var fullTrack: some View {
        HStack(spacing: 0) {
            let items = PlanText.track(current: stage)
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                step(index: index, name: item.name, state: item.state, showLabel: true)
                if index < items.count - 1 { join(done: item.state == .done, minWidth: 8, padding: 6) }
            }
        }
    }

    /// All four circles; only the current stage keeps its label, the others say theirs on hover.
    private var circlesTrack: some View {
        HStack(spacing: 0) {
            let items = PlanText.track(current: stage)
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                step(index: index, name: item.name, state: item.state, showLabel: item.state == .current)
                    .help(PlanText.title(item.name))
                if index < items.count - 1 { join(done: item.state == .done, minWidth: 6, padding: 4) }
            }
        }
    }

    private func join(done: Bool, minWidth: CGFloat, padding: CGFloat) -> some View {
        Rectangle()
            .fill(done ? Theme.Colors.ok : Theme.Colors.line2)
            .frame(height: 1)
            .frame(minWidth: minWidth, maxWidth: .infinity)
            .padding(.horizontal, padding)
    }

    private func step(index: Int, name: PlanStageName, state: PlanText.TrackState, showLabel: Bool) -> some View {
        HStack(spacing: 6) {
            PlanTrackDot(index: index, state: state, size: 20)
            if showLabel {
                Text(PlanText.title(name))
                    .knockTextStyle(state == .current ? Theme.Typography.rowLabel12_5w500 : Theme.Typography.recommendLine12w400)
                    .foregroundColor(state == .upcoming ? Theme.Colors.ink3 : Theme.Colors.ink)
                    .fixedSize()
            }
        }
    }
}

/// One numbered circle of a track: a tick when done, dark when current, an outline when upcoming.
struct PlanTrackDot: View {
    let index: Int
    let state: PlanText.TrackState
    let size: CGFloat

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(Theme.Colors.ok)
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.Colors.win)
            case .current:
                Circle().fill(Theme.Colors.ink)
                Text("\(index + 1)").font(.system(size: 10.5, weight: .semibold)).foregroundColor(Theme.Colors.win)
            case .upcoming:
                Circle().stroke(Theme.Colors.line2, lineWidth: 1.2)
                Text("\(index + 1)").font(.system(size: 10.5, weight: .medium)).foregroundColor(Theme.Colors.ink3)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The narrowest form: "Stage 2 of 4 · Approaches" and four small dots (done and current lit).
struct PlanTrackLineView: View {
    let stage: PlanStageName
    let font: Theme.TextStyle

    var body: some View {
        HStack(spacing: 8) {
            Text(PlanTrackLayout.line(stage)).knockTextStyle(font).foregroundColor(Theme.Colors.ink).fixedSize()
            HStack(spacing: 4) {
                ForEach(Array(PlanText.track(current: stage).enumerated()), id: \.offset) { _, item in
                    Circle()
                        .fill(item.state == .done ? Theme.Colors.ok : (item.state == .current ? Theme.Colors.ink : Theme.Colors.line2))
                        .frame(width: 6, height: 6)
                }
            }
        }
    }
}

/// One earlier round for the fold: what was asked and what you answered.
struct RoundFoldEntry: Equatable {
    let question: String
    let answer: String
    /// "See vN" for a plan round that has its own revision.
    var revision: Int? = nil
    var seeLabel: String? = nil
    var seq: Int? = nil
}

/// "2 answered · Show": the earlier rounds folded away, read-only when opened (HAIL-151). Plan rounds and
/// update rounds use this one fold (WAG-335).
struct RoundFoldView: View {
    let entries: [RoundFoldEntry]
    /// The revision the stage shows read-only right now, else `nil` (HAIL-156).
    var viewingRevision: Int? = nil
    /// "See vN": opens that round's artifact read-only on the stage. `nil` hides the links.
    var onSeeRevision: ((Int) -> Void)? = nil
    @State private var isOpen = ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_PLAN_FOLD_OPEN"] == "1"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Colors.ok)
                    Text(PlanText.answeredLabel(entries.count))
                        .knockTextStyle(Theme.Typography.rowLabel12_5w500)
                        .foregroundColor(Theme.Colors.ink)
                    Spacer(minLength: 0)
                    Text(isOpen ? "Hide" : "Show")
                        .knockTextStyle(Theme.Typography.recommendLine12w400)
                        .foregroundColor(Theme.Colors.ink3)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.Colors.ink3)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.question)
                                    .knockTextStyle(Theme.Typography.recommendLine12w400)
                                    .foregroundColor(Theme.Colors.ink3)
                                    .lineLimit(2)
                                Text(entry.answer)
                                    .knockTextStyle(Theme.Typography.rowLabel12_5w500)
                                    .foregroundColor(Theme.Colors.ink)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            if let onSeeRevision, let revision = entry.revision, let label = entry.seeLabel {
                                if viewingRevision == revision {
                                    Text("Viewing")
                                        .knockTextStyle(Theme.Typography.recommendLine12w400)
                                        .foregroundColor(Theme.Colors.ink3)
                                } else {
                                    Button(label) { onSeeRevision(revision) }
                                        .buttonStyle(.plain).pointerCursor()
                                        .knockTextStyle(Theme.Typography.priorRevisionLink12w500)
                                        .foregroundColor(Theme.Colors.ds)
                                        .accessibilityIdentifier("plan-see-round-\(entry.seq ?? 0)")
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 2, leading: 12, bottom: 10, trailing: 12))
            }
        }
        .background(Theme.Colors.list)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.recommendedBlock).stroke(Theme.Colors.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.recommendedBlock))
    }
}

/// The plan's earlier answered rounds as fold entries.
extension PlanText {
    static func foldEntries(_ rounds: [PlanRound]) -> [RoundFoldEntry] {
        rounds.map { round in
            RoundFoldEntry(
                question: AgentMarkdown.singleLine(round.question), answer: answerSummary(round),
                revision: round.revision, seeLabel: PlanArtifacts.seeLabel(round), seq: round.seq)
        }
    }
}

/// The plan part of the right column: the track, the progress line and the folded answers.
struct PlanColumnHeaderView: View {
    let plan: PlanInfo
    let rounds: [PlanRound]
    var viewingRevision: Int? = nil
    var onSeeRevision: ((Int) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The same "Round 2" mark as an update round (WAG-335).
            if plan.rounds > 1 { RoundTagView(text: "Round \(plan.rounds)") }
            PlanStageTrackView(stage: plan.stage.name)
            Text(PlanText.progressLabel(plan.stage).uppercased())
                .knockTextStyle(Theme.Typography.labelCaps10_5w600)
                .foregroundColor(Theme.Colors.ink3)
            let earlier = PlanText.earlierAnswered(rounds)
            if !earlier.isEmpty {
                RoundFoldView(entries: PlanText.foldEntries(earlier), viewingRevision: viewingRevision, onSeeRevision: onSeeRevision)
            }
        }
    }
}

/// A plan round's text in the right column, read like a readme (operator, 4 Oct): the first sentence as
/// the bold headline, the rest as regular safe markdown under it. A one-line round looks as before.
struct PlanQuestionView: View {
    let text: String

    var body: some View {
        let parts = PlanText.questionParts(text)
        VStack(alignment: .leading, spacing: 8) {
            if !parts.headline.isEmpty {
                AgentMarkdownText(text: parts.headline, style: Theme.Typography.cardTitle15w650)
            }
            if let body = parts.body {
                AgentMarkdownText(text: body, style: Theme.Typography.body13w400)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
