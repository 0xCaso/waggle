import Testing
import Foundation
@testable import Knock

/// Exercises `NotificationBuilder` against the KNOCK-09 contract text and the
/// M2 mock's sample case (docs/design/mvp-values.md §M2 `HS75s`: "Checkout
/// redesign needs you" / "Checkout layout: compact or detailed?" / "Recommends
/// A · Compact").
struct NotificationBuilderTests {
    @Test func buildsTitleAndBodyFromTaskAndCaseWithAnOptionRecommendation() {
        let task = KnockTask(id: "t_2", name: "Checkout redesign", project: "omea-web")
        let knockCase = Case(
            id: "c_old",
            taskId: "t_2",
            kind: .review,
            title: "Checkout layout: compact or detailed?",
            need: "N", why: "W",
            recommendation: "a",
            recommendationWhy: "RW",
            options: [Option(id: "a", label: "A · Compact")],
            status: .needsYou,
            hasArtifact: true,
            createdAt: "2026-09-26T10:00:00.000Z",
            updatedAt: "2026-09-26T10:00:00.000Z"
        )

        let content = NotificationBuilder.content(
            for: knockCase, task: task,
            environment: [:], bundleIdentifier: TestCopyEnvironment.releaseBundleIdentifier
        )

        #expect(content.caseId == "c_old")
        #expect(content.identifier == "case.c_old")
        #expect(content.title == "Claude needs your review: Checkout layout: compact or detailed?")
        #expect(content.subtitle == "Claude Code")
        #expect(content.body == "Omea web · Recommends Compact")
    }

    @Test func showsTheCodexSubtitleForACodexCase() {
        let task = KnockTask(id: "t_3", name: "Checkout redesign", project: "omea-web")
        let knockCase = Case(
            id: "c_codex",
            taskId: "t_3",
            kind: .review,
            title: "Checkout layout: compact or detailed?",
            need: "N", why: "W",
            recommendation: "a",
            recommendationWhy: "RW",
            options: [Option(id: "a", label: "A · Compact")],
            status: .needsYou,
            hasArtifact: true,
            runtime: .codex,
            createdAt: "2026-09-26T10:00:00.000Z",
            updatedAt: "2026-09-26T10:00:00.000Z"
        )

        let content = NotificationBuilder.content(for: knockCase, task: task)

        #expect(content.subtitle == "Codex")
    }

    @Test func fallsBackToFreeTextRecommendationWhenNoOptionMatches() {
        let task = KnockTask(id: "t_1", name: "Card pricing", project: "weekend-league")
        let knockCase = Case(
            id: "c_new",
            taskId: "t_1",
            kind: .question,
            title: "Rarity weights for the first pack",
            need: "N", why: "W",
            recommendation: "70 / 25 / 5",
            recommendationWhy: "RW",
            options: [],
            status: .needsYou,
            hasArtifact: false,
            createdAt: "2026-09-26T10:10:00.000Z",
            updatedAt: "2026-09-26T10:10:00.000Z"
        )

        let content = NotificationBuilder.content(
            for: knockCase, task: task,
            environment: [:], bundleIdentifier: TestCopyEnvironment.releaseBundleIdentifier
        )

        #expect(content.title == "Claude needs your decision: Rarity weights for the first pack")
        #expect(content.body == "Weekend league · Recommends 70 / 25 / 5")
    }

    // MARK: - "Show the question in the notification" off (Contract)

    @Test func hidesTheQuestionWhenShowsQuestionIsFalse() {
        let task = KnockTask(id: "t_7", name: "Checkout redesign", project: "omea-web")
        let knockCase = Case(
            id: "c_hidden",
            taskId: "t_7",
            kind: .review,
            title: "Checkout layout: compact or detailed?",
            need: "N", why: "W",
            recommendation: "a",
            recommendationWhy: "RW",
            options: [Option(id: "a", label: "A · Compact")],
            status: .needsYou,
            hasArtifact: true,
            project: "omea-web",
            createdAt: "2026-09-26T10:00:00.000Z",
            updatedAt: "2026-09-26T10:00:00.000Z"
        )

        let content = NotificationBuilder.content(
            for: knockCase, task: task, showsQuestion: false,
            environment: [:], bundleIdentifier: TestCopyEnvironment.releaseBundleIdentifier
        )

        #expect(content.title == "Your agent needs a decision")
        #expect(content.subtitle == "")
        #expect(content.body == "Omea web")
        #expect(!content.body.contains("Checkout layout"))
        #expect(!content.title.contains("Checkout redesign"))
    }

    @Test func showsQuestionTrueKeepsTheContractText() {
        let task = KnockTask(id: "t_8", name: "Checkout redesign", project: "omea-web")
        let knockCase = Case(
            id: "c_shown",
            taskId: "t_8",
            kind: .review,
            title: "Checkout layout: compact or detailed?",
            need: "N", why: "W",
            recommendation: "a",
            recommendationWhy: "RW",
            options: [Option(id: "a", label: "A · Compact")],
            status: .needsYou,
            hasArtifact: true,
            createdAt: "2026-09-26T10:00:00.000Z",
            updatedAt: "2026-09-26T10:00:00.000Z"
        )

        let content = NotificationBuilder.content(
            for: knockCase, task: task, showsQuestion: true,
            environment: [:], bundleIdentifier: TestCopyEnvironment.releaseBundleIdentifier
        )

        #expect(content.title == "Claude needs your review: Checkout layout: compact or detailed?")
        #expect(content.body == "Omea web · Recommends Compact")
    }

    // MARK: - "[test] " prefix (docs/stories/HAIL-34.md operator report 21:51)

    @Test func noTestPrefixForTheReleaseBundleAndTheDefaultHome() {
        let task = KnockTask(id: "t_4", name: "Checkout redesign", project: "omea-web")
        let knockCase = Case(
            id: "c_real",
            taskId: "t_4",
            kind: .review,
            title: "Checkout layout: compact or detailed?",
            need: "N", why: "W",
            recommendation: "a",
            recommendationWhy: "RW",
            options: [Option(id: "a", label: "A · Compact")],
            status: .needsYou,
            hasArtifact: true,
            createdAt: "2026-09-26T10:00:00.000Z",
            updatedAt: "2026-09-26T10:00:00.000Z"
        )

        let content = NotificationBuilder.content(
            for: knockCase, task: task,
            environment: [:], bundleIdentifier: "dev.limone.knock"
        )

        #expect(content.title == "Claude needs your review: Checkout layout: compact or detailed?")
    }

    @Test func testPrefixForACustomKnockHome() {
        let task = KnockTask(id: "t_5", name: "Checkout redesign", project: "omea-web")
        let knockCase = Case(
            id: "c_test_home",
            taskId: "t_5",
            kind: .review,
            title: "Checkout layout: compact or detailed?",
            need: "N", why: "W",
            recommendation: "a",
            recommendationWhy: "RW",
            options: [Option(id: "a", label: "A · Compact")],
            status: .needsYou,
            hasArtifact: true,
            createdAt: "2026-09-26T10:00:00.000Z",
            updatedAt: "2026-09-26T10:00:00.000Z"
        )

        let content = NotificationBuilder.content(
            for: knockCase, task: task,
            environment: ["KNOCK_HOME": "/tmp/knock-evidence"], bundleIdentifier: "dev.limone.knock"
        )

        #expect(content.title == "[test] Claude needs your review: Checkout layout: compact or detailed?")
    }

    @Test func testPrefixForANonReleaseBundleId() {
        let task = KnockTask(id: "t_6", name: "Checkout redesign", project: "omea-web")
        let knockCase = Case(
            id: "c_test_bundle",
            taskId: "t_6",
            kind: .review,
            title: "Checkout layout: compact or detailed?",
            need: "N", why: "W",
            recommendation: "a",
            recommendationWhy: "RW",
            options: [Option(id: "a", label: "A · Compact")],
            status: .needsYou,
            hasArtifact: true,
            createdAt: "2026-09-26T10:00:00.000Z",
            updatedAt: "2026-09-26T10:00:00.000Z"
        )

        let content = NotificationBuilder.content(
            for: knockCase, task: task,
            environment: [:], bundleIdentifier: "dev.limone.knock.dev"
        )

        #expect(content.title == "[test] Claude needs your review: Checkout layout: compact or detailed?")
    }

    // MARK: - HAIL-231: readable names

    private func ask(project: String, taskName: String = "", client: String? = nil, canNudge: Bool? = nil) -> (Case, KnockTask) {
        let knockCase = Case(
            id: "c_n", taskId: "t_n", kind: .question, title: "Which one?",
            need: "N", why: "W", recommendation: "a", recommendationWhy: "RW",
            options: [], status: .needsYou, hasArtifact: false,
            sessionCanNudge: canNudge, sessionClientName: client, taskName: taskName, project: project,
            createdAt: "2026-10-06T10:00:00.000Z", updatedAt: "2026-10-06T10:00:00.000Z"
        )
        return (knockCase, knockCase.knockTask)
    }

    private func body(_ project: String, taskName: String = "") -> String {
        let (c, t) = ask(project: project, taskName: taskName)
        return NotificationBuilder.content(for: c, task: t, environment: [:], bundleIdentifier: TestCopyEnvironment.releaseBundleIdentifier).body
    }

    @Test func bodyNamesTheWorkNotTheBranchOrWorktree() {
        #expect(body("fragrant-hospital-fc8f1973", taskName: "session-context-proto-fc8f1973") == "Fragrant hospital · Recommends a")
        #expect(body("brawny-fiction-86b69062") == "Brawny fiction · Recommends a")
        #expect(body("HAIL-224", taskName: "story/HAIL-224") == "HAIL 224 · Recommends a")
        #expect(body("Syllotips launch email") == "Syllotips launch email · Recommends a")
    }

    @Test func hiddenQuestionBodyIsTheReadableNameToo() {
        let (c, t) = ask(project: "/work/fragrant-hospital-fc8f1973")
        let content = NotificationBuilder.content(for: c, task: t, showsQuestion: false, environment: [:], bundleIdentifier: TestCopyEnvironment.releaseBundleIdentifier)
        #expect(content.body == "Fragrant hospital")
    }

    @Test func subtitleIsTheRuntimeInWords() {
        for (client, label) in [("local-agent-mode-waggle", "Cowork"), ("claude-ai", "Claude app")] {
            let (c, t) = ask(project: "x", client: client, canNudge: false)
            let content = NotificationBuilder.content(for: c, task: t, environment: [:], bundleIdentifier: TestCopyEnvironment.releaseBundleIdentifier)
            #expect(content.subtitle == label)
        }
        let (c, t) = ask(project: "x", client: "claude-code", canNudge: true)
        #expect(NotificationBuilder.content(for: c, task: t).subtitle == "Claude Code")
    }
}
