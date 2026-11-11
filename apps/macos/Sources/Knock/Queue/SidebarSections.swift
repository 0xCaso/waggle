import SwiftUI

/// WAG-255: what the sidebar lists under "New idea" besides Needs you: the working projects, the
/// open plans and the folded quiet projects. Pure, so the rows are unit-tested without a window.
enum SidebarSections {
    struct WorkingRow: Equatable, Identifiable {
        let id: String
        /// The row title: the session title (WAG-279), else the project in plain words.
        let name: String
        /// "<project> · <doing now> · <time>" under a session title; "<doing now> · <time>" when the
        /// project is the title. The line alone when there is no time.
        let meta: String
        let openCaseId: String?
        /// The first job of onboarding went to this session (WAG-344): the row carries a "First job" tag.
        var isFirstJob = false
        /// The row is "Your agent is on it", with no session row yet: it is not a case and opens nothing.
        var isOnboarding = false
    }

    struct PlanRow: Equatable, Identifiable {
        let id: String
        let title: String
        let stage: String
        let needsYou: Bool
        /// "Questions · needs you" or "Questions · working".
        var meta: String { "\(stage) · \(needsYou ? "needs you" : "working")" }
    }

    /// Every sidebar section header: caps, "NEEDS YOU · 1". One style (WAG-279); the view is `SidebarSectionTitle`.
    static func sectionTitle(_ label: String, count: Int) -> String {
        "\(label.uppercased()) · \(count)"
    }

    static func stageWord(_ name: PlanStageName) -> String {
        switch name {
        case .questions: "Questions"
        case .approaches: "Approaches"
        case .design: "Design"
        case .spec: "Spec"
        }
    }

    /// Projects an agent is working on and that do not wait on you (those sit in Needs you).
    /// `held` is the asks you answered that the agent has not finished with. A project with one shows
    /// "Working on your answer: <title>" and its row opens that ask (WAG-272).
    static func workingRows(
        _ overview: HomeCards.Overview, held: [Case] = [], firstJob: AgentOnIt? = nil, now: Date = Date()
    ) -> [WorkingRow] {
        let jobCard = firstJob.flatMap { firstJobCardId(overview, job: $0) }
        let live = held.filter { !$0.isDone && !AnswerGrouping.isClosed($0) && $0.status == .waitingOnAgent }
        var rows = overview.cards.filter { $0.state == .working }.map { card in
            let answer = live.first { ProjectName.display(project: $0.project).lowercased() == card.id }
            let line = answer.map { "Working on your answer: \($0.rowTitle)" } ?? card.line
            let detail = card.ago.isEmpty ? line : "\(line) · \(card.ago)"
            let title = card.sessionTitle
            return WorkingRow(
                id: card.id, name: title ?? card.name,
                meta: title == nil ? detail : "\(card.name) · \(detail)",
                openCaseId: answer?.id ?? card.openCaseId, isFirstJob: card.id == jobCard)
        }
        // WAG-344: with no session row for the first job yet, "Your agent is on it" joins this list.
        if let firstJob, jobCard == nil {
            rows.insert(WorkingRow(
                id: "first-job", name: "Your agent is on it", meta: firstJob.queueLine(now: now),
                openCaseId: nil, isOnboarding: true), at: 0)
        }
        return rows
    }

    /// The working card of the session that took the first job: the job's project, the job's agent, and
    /// activity since the job was sent. Nil while no such row exists (a Terminal session still starting).
    /// Working shows its rows when the saved choice is open, and always while the onboarding
    /// first job is in it, so a new user sees that their first job started (C11 exception).
    static func workingShowsRows(_ rows: [WorkingRow], saved: Bool) -> Bool {
        saved || rows.contains { $0.isFirstJob || $0.isOnboarding }
    }

    static func firstJobCardId(_ overview: HomeCards.Overview, job: AgentOnIt) -> String? {
        let project = job.projectName.lowercased()
        return overview.cards.first { card in
            card.state == .working && card.id == project && card.latestAt >= job.since
                && (job.agent == AgentOnIt.unknownAgent || card.agents.contains { sameAgent($0, job.agent) })
        }?.id
    }

    /// "Claude Code" and "Claude" are one agent; the Claude app and Cowork are others.
    private static func sameAgent(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> String {
            let l = s.lowercased()
            if l.contains("cowork") { return "cowork" }
            if l.contains("claude app") || l.contains("desktop") { return "app" }
            return l.contains("claude") ? "claude" : l
        }
        return key(a) == key(b)
    }

    /// WAG-343: the asks an agent still holds that Answered lists. An ask that a Working row or an In
    /// planning row already opens is not listed a second time. A failed reply stays in Answered, so
    /// Retry is still there.
    static func heldAsks(_ held: [Case], overview: HomeCards.Overview, activeCases: [Case]) -> [Case] {
        var shownAbove = Set(workingRows(overview, held: held).compactMap(\.openCaseId))
        shownAbove.formUnion(planRows(activeCases).map(\.id))
        return held.filter { !shownAbove.contains($0.id) || $0.latestReplyState == .failed }
    }

    /// One row per plan the agent is working on (WAG-297): a plan (`Case.plan`, the wire `kind` stays
    /// "question") that is not finished, withdrawn or dismissed. A plan that needs you shows once, in
    /// Needs you, with its stage in the meta line.
    static func planRows(_ cases: [Case]) -> [PlanRow] {
        cases.compactMap { item -> PlanRow? in
            guard let plan = item.plan, !item.isDone, item.withdrawnAt == nil, item.dismissedAt == nil,
                  item.status == .waitingOnAgent
            else { return nil }
            return PlanRow(id: item.id, title: item.rowTitle, stage: stageWord(plan.stage.name), needsYou: false)
        }
    }
}

extension Theme.Typography {
    static let sidebarItem13w500 = Theme.TextStyle(
        font: .custom(Theme.FontFamily.sans, size: 13).weight(.medium), size: 13, lineHeight: nil, letterSpacing: nil)
    static let sidebarItemMeta11_5 = Theme.TextStyle(
        font: .custom(Theme.FontFamily.sans, size: 11.5), size: 11.5, lineHeight: nil, letterSpacing: nil)
}

// MARK: - Views

/// A small sidebar header ("NEEDS YOU · 1", "WORKING · 2", "ANSWERED · 5"): one style for every section, mockup B's
/// `.sec` (600 10.5/1, 0.06 em, caps, quiet, padding 14 16 6).
struct SidebarSectionTitle: View {
    let text: String

    var body: some View {
        ChromeSectionLabel(text: text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.AskDoc.Chrome.sectionInset)
    }
}

/// A section header that folds: "› WORKING · 2 ... Show" closed, "⌄ WORKING · 2 ... Hide" open. Answered, Working
/// and Decided for you use it. The label is the `.sec` caps; the word on the right is B's `.sec button` ("Show all
/// 271": 500 12, ink3, no caps); the chevron is the case map's "›".
struct SidebarFoldHeader: View {
    let label: String
    let count: Int
    let isOpen: Bool
    /// The whole title when it is not "LABEL · N" ("Decided for you · 3 today").
    var title: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(Theme.AskDoc.Colors.quiet)
                    .frame(width: 8)
                ChromeSectionLabel(text: title ?? SidebarSections.sectionTitle(label, count: count))
                Spacer(minLength: 0)
                Text(isOpen ? "Hide" : "Show")
                    .knockTextStyle(Theme.AskDoc.Chrome.sectionButton)
                    .foregroundColor(Theme.Colors.ink3)
            }
            .padding(Theme.AskDoc.Chrome.sectionInset)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
    }
}

/// A Working or In planning row in the `.row` look; the title in 500 ink as the case map's working row.
private struct SidebarItemRow: View {
    let dot: Color
    let pulses: Bool
    let title: String
    let meta: String
    var tag: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.AskDoc.Chrome.rowGap) {
                RowDot(color: dot, pulses: pulses).sidebarDotOnBaseline()
                VStack(alignment: .leading, spacing: Theme.AskDoc.Chrome.rowMetaGap) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title)
                            .knockTextStyle(Theme.AskDoc.Chrome.rowTitleDone)
                            .foregroundColor(Theme.Colors.ink)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let tag {
                            Text(tag)
                                .knockTextStyle(Theme.Typography.tagLabel10_5w500)
                                .foregroundColor(Theme.Colors.accent)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Theme.Colors.accentSoft)
                                .clipShape(Capsule())
                                .fixedSize()
                        }
                    }
                    if !meta.isEmpty {
                        Text(meta)
                            .knockTextStyle(Theme.AskDoc.Chrome.rowMeta)
                            .foregroundColor(Theme.AskDoc.Colors.quiet)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.AskDoc.Chrome.rowInset)
            .background(isSelected ? Theme.AskDoc.Chrome.selectedFill : Color.clear)
            .overlay(alignment: .leading) {
                if isSelected { Rectangle().fill(Theme.AskDoc.Chrome.selectedBar).frame(width: Theme.AskDoc.Chrome.selectedBarWidth) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
    }
}

/// WORKING and IN PLANNING, in that order. Working folds (C11): closed by default, the choice saved.
struct SidebarWorkSections: View {
    @ObservedObject var model: AppModel
    /// "Your agent is on it", or nil (WAG-344). It joins Working, on the session's row once one exists.
    var firstJob: AgentOnIt? = nil

    var body: some View {
        let working = SidebarSections.workingRows(
            model.homeOverview, held: model.stillWaitingCases, firstJob: firstJob, now: model.now)
        let plans = SidebarSections.planRows(model.activeCases)
        VStack(spacing: 0) {
            if !working.isEmpty {
                let showRows = SidebarSections.workingShowsRows(working, saved: model.workingOpen)
                SidebarFoldHeader(label: "Working", count: working.count, isOpen: showRows) {
                    model.workingOpen = !showRows
                }
                .accessibilityIdentifier("working-fold")
                if showRows {
                    ForEach(working) { row in
                        SidebarItemRow(
                            dot: Theme.Colors.ds, pulses: true, title: row.name, meta: row.meta,
                            tag: row.isFirstJob ? "First job" : nil, isSelected: false
                        ) { open(row.openCaseId) }
                        .accessibilityIdentifier(row.isOnboarding ? "agent-on-it-row" : "working-row")
                    }
                }
            }
            if !plans.isEmpty {
                SidebarSectionTitle(text: SidebarSections.sectionTitle("In planning", count: plans.count))
                ForEach(plans) { row in
                    SidebarItemRow(
                        dot: row.needsYou ? Theme.Colors.accent : Theme.Colors.ds, pulses: !row.needsYou,
                        title: row.title, meta: row.meta, isSelected: row.id == model.selectedCaseId
                    ) { open(row.id) }
                }
            }
        }
    }

    private func open(_ caseId: String?) {
        guard let caseId else { return }
        Task { await model.open(caseId: caseId, source: .queue) }
    }
}
