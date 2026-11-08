import Foundation

/// Builds the notification content for a `needs_you` case.
///
/// Contract (KNOCK-09): "Title `<task> needs you`, body `<title> ·
/// Recommends <value>`". The M2 mock (`HS75s` → `bjRms`) draws the case
/// title and the recommendation as two stacked lines inside the
/// illustrated notification card, but `UNNotificationContent` only exposes
/// title/subtitle/body; the contract's literal joined string wins here
/// (see the story's Choices ledger).
enum NotificationBuilder {
    /// HAIL-231: the work in plain words, the same name the queue rows show (`ProjectName`, HAIL-191):
    /// the topic when the ask has one, else the cleaned folder name. Never the task name, which can be
    /// a branch or a session label.
    static func workName(for knockCase: Case, task: KnockTask) -> String {
        let project = knockCase.project.isEmpty ? task.project : knockCase.project
        return ProjectName.display(project: project)
    }

    /// `environment` follows the same injectable-`ProcessInfo` pattern as
    /// `ComposerViewModel`/`ReviewViewModel`: a test copy's every
    /// notification title starts with "[test] " (docs/stories/HAIL-34.md
    /// operator report 21:51), so a worker's evidence run is never
    /// mistakable for the operator's own. `bundleIdentifier` rides along for
    /// the same reason `TestCopyEnvironment.isActive` takes one: a unit test
    /// runs inside the test runner's own bundle, never the app's, so
    /// exercising the "no prefix" branch needs a way to say "pretend this is
    /// the release bundle" without touching `Bundle.main` itself.
    /// `showsQuestion` is the Settings page's "Show the decision in the
    /// notification" toggle (Contract), read by the caller: off drops the
    /// task/case/recommendation text entirely and posts only a fixed title
    /// plus the project name, so a screen-shared notification never leaks
    /// what the agent is asking.
    static func content(
        for knockCase: Case, task: KnockTask,
        showsQuestion: Bool = true,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> NotificationContent {
        let title: String
        let subtitle: String
        let body: String
        if showsQuestion {
            // HAIL-176: "Claude needs your decision: <title>" ("review" for a review), the item itself in the title.
            let agent = knockCase.runtime == .codex ? "Codex" : "Claude"
            title = "\(agent) needs your \(knockCase.kind == .review ? "review" : "decision"): \(knockCase.rowTitle)"
            subtitle = knockCase.runtimeLabel
            body = "\(workName(for: knockCase, task: task)) · Recommends \(AgentMarkdown.singleLine(knockCase.recommendationDisplay))"
        } else {
            title = "Your agent needs a decision"
            subtitle = ""
            body = workName(for: knockCase, task: task)
        }
        let isTestCopy = TestCopyEnvironment.isActive(environment: environment, bundleIdentifier: bundleIdentifier)
        return NotificationContent(
            identifier: "case.\(knockCase.id)",
            caseId: knockCase.id,
            title: isTestCopy ? "[test] \(title)" : title,
            subtitle: subtitle,
            body: body
        )
    }

    /// The notification for an ask that came back after your reply (HAIL-67):
    /// title "Updated: <title>", the agent's message as the body. Its own
    /// identifier, so it does not replace the ask's first notification. With
    /// "Show the decision" off it keeps the same fixed text as a new ask, so
    /// nothing the agent wrote leaks. `nil` when the case has no update to
    /// tell about.
    static func updateContent(
        for knockCase: Case,
        showsQuestion: Bool = true,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> NotificationContent? {
        guard let update = knockCase.pendingUpdate else { return nil }
        let title: String
        let subtitle: String
        let body: String
        if showsQuestion {
            title = "Updated: \(knockCase.rowTitle)"
            subtitle = knockCase.runtimeLabel
            body = AgentMarkdown.singleLine(update.firstLine)
        } else {
            title = "Your agent needs a decision"
            subtitle = ""
            body = workName(for: knockCase, task: knockCase.knockTask)
        }
        let isTestCopy = TestCopyEnvironment.isActive(environment: environment, bundleIdentifier: bundleIdentifier)
        return NotificationContent(
            identifier: "case.\(knockCase.id).update",
            caseId: knockCase.id,
            title: isTestCopy ? "[test] \(title)" : title,
            subtitle: subtitle,
            body: body
        )
    }
}
