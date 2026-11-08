import Foundation

/// Loads and changes one project's page (WAG-260). The daemon owns the data; this only asks and
/// shows. A failed load keeps what is on screen.
@MainActor
final class ProjectPageModel: ObservableObject {
    let project: String
    private let client: KnockClient

    @Published private(set) var info: ProjectInfo?
    @Published private(set) var decisions: [ProjectDecision] = []
    @Published private(set) var total = 0
    @Published private(set) var loaded = false
    @Published private(set) var loadingMore = false

    init(project: String, client: KnockClient) {
        self.project = project
        self.client = client
    }

    var name: String { ProjectName.display(project: project) }
    var hasMore: Bool { decisions.count < total }

    func load() async {
        UsageReporter.current?.record(.projectPageOpened)
        do {
            async let info = client.projectInfo(project)
            async let page = client.projectDecisions(project, limit: ProjectPageLogic.pageSize, offset: 0)
            let (i, p) = try await (info, page)
            self.info = i
            decisions = p.items
            total = p.total
        } catch {
            // Keep the last good page.
        }
        loaded = true
    }

    func loadMore() async {
        guard hasMore, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let page = try? await client.projectDecisions(project, limit: ProjectPageLogic.pageSize, offset: decisions.count) {
            decisions += page.items
            total = page.total
        }
    }

    func setTheme(_ theme: ProjectTheme, enabled: Bool) async {
        guard let current = info else { return }
        apply(current, themeId: theme.id, enabled: enabled)
        do {
            try await client.setProjectTheme(id: theme.id, enabled: enabled)
        } catch {
            if let latest = info { apply(latest, themeId: theme.id, enabled: !enabled) }
        }
    }

    func setRepoRecords(_ on: Bool) async {
        guard let current = info else { return }
        info = ProjectInfo(
            project: current.project, decisions: current.decisions, comments: current.comments,
            lastDecisionAt: current.lastDecisionAt, repoRecords: on, themes: current.themes)
        do {
            try await client.setProjectRepoRecords(project, enabled: on)
        } catch {
            if let latest = info {
                info = ProjectInfo(
                    project: latest.project, decisions: latest.decisions, comments: latest.comments,
                    lastDecisionAt: latest.lastDecisionAt, repoRecords: !on, themes: latest.themes)
            }
        }
    }

    private func apply(_ current: ProjectInfo, themeId: String, enabled: Bool) {
        var themes = current.themes
        if let index = themes.firstIndex(where: { $0.id == themeId }) { themes[index].enabled = enabled }
        info = ProjectInfo(
            project: current.project, decisions: current.decisions, comments: current.comments,
            lastDecisionAt: current.lastDecisionAt, repoRecords: current.repoRecords, themes: themes)
    }
}
