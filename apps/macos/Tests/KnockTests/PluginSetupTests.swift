import Testing
import Foundation
@testable import Knock

/// HAIL-138: the checklist after "Install plugin": steps, rows, detection of "seen", persistence.
@MainActor
struct PluginSetupTests {
    private let installed = KnockDateFormat.date(from: "2026-10-02T10:00:00Z")!
    private let later = KnockDateFormat.date(from: "2026-10-02T10:05:00Z")!

    private let mcpMode = [
        "ok    Claude Code installed as MCP entry",
        "ok    Claude Code can install the Waggle plugin",
    ]
    private let pluginMode = [
        "ok    Claude Code installed as plugin",
        "ok    Claude Code can install the Waggle plugin",
    ]

    private func session(
        _ id: String = "s1", live: String? = nil, runtime: Runtime = .claude, state: SessionState = .live,
        title: String? = nil
    ) -> SessionInfo {
        SessionInfo(
            id: id, taskId: "task-\(id)", runtime: runtime, taskName: "negozio", project: "knock", branch: nil,
            cwd: "/tmp", state: state, connectedAt: "2026-10-02T09:00:00Z", lastSeenAt: "2026-10-02T10:01:00Z",
            context: SessionContext(title: title, live: live.map { LiveState(phase: "idle", lastEventAt: $0) }))
    }

    private func ask(task: String, createdAt: String) -> Case {
        Case(
            id: "c1", taskId: task, kind: .question, title: "Colour?", need: "N", why: "W", recommendation: "R",
            recommendationWhy: "RW", options: [Option(id: "o1", label: "Blue", title: "Blue")],
            status: .needsYou, hasArtifact: false, createdAt: createdAt, updatedAt: createdAt)
    }

    private func freshDefaults() -> UserDefaults {
        let name = "knock-plugin-setup-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: State machine

    @Test func movesFromInstalledToWaitingToSeenToTestAskToDone() {
        var setup = PluginSetup(installedAt: installed, hadOldConnection: true)
        #expect(setup.step == .waiting)
        let changed3480 = setup.observe(sessions: [session()], cases: [], now: later)
        #expect(!changed3480)

        let changed5641 = setup.observe(sessions: [session(live: "2026-10-02T10:04:00Z", title: "Fix login")], cases: [], now: later)
        #expect(changed5641)
        #expect(setup.step == .seen)
        #expect(setup.seenName == "Fix login")

        let changed358 = setup.observe(sessions: [], cases: [ask(task: "task-s1", createdAt: "2026-10-02T10:06:00Z")], now: later)
        #expect(changed358)
        #expect(setup.step == .working)

        setup.finished = true
        #expect(!setup.isActive)
    }

    @Test func rowsFollowTheStep() {
        var setup = PluginSetup(installedAt: installed, hadOldConnection: true)
        #expect(setup.rows(now: later).map(\.title) == [
            "Plugin installed", "Old connection removed", "Waiting for a Claude Code session…",
        ])
        setup.observe(sessions: [session(live: "2026-10-02T10:04:30Z")], cases: [], now: later)
        #expect(setup.rows(now: later).last == .init(title: "Seen in negozio · just now", state: .done))
        setup.observe(sessions: [], cases: [ask(task: "task-s1", createdAt: "2026-10-02T10:06:00Z")], now: later)
        #expect(setup.rows(now: later).last == .init(title: "Test decision arrived", state: .done))
        #expect(setup.rows(now: later).count == 4)
    }

    @Test func noOldConnectionRowWhenThereWasNone() {
        let setup = PluginSetup(installedAt: installed, hadOldConnection: false)
        #expect(setup.rows(now: later).map(\.title) == ["Plugin installed", "Waiting for a Claude Code session…"])
    }

    @Test func skipHidesTheCardForGood() {
        var setup = PluginSetup(installedAt: installed, hadOldConnection: true)
        setup.finished = true
        let changed6935 = setup.observe(sessions: [session(live: "2026-10-02T10:04:00Z")], cases: [], now: later)
        #expect(!changed6935)
        #expect(setup.step == .waiting)
    }

    @Test func aTestAskNeedsTheSeenSessionAndAFreshCase() {
        var setup = PluginSetup(installedAt: installed, hadOldConnection: false)
        // An ask before the session is seen does not count.
        setup.observe(sessions: [], cases: [ask(task: "task-s1", createdAt: "2026-10-02T10:06:00Z")], now: later)
        #expect(setup.step == .waiting)
        setup.observe(sessions: [session(live: "2026-10-02T10:04:00Z")], cases: [], now: later)
        // Another session's ask, and an ask from before the install, do not count.
        setup.observe(sessions: [], cases: [
            ask(task: "task-other", createdAt: "2026-10-02T10:06:00Z"),
            ask(task: "task-s1", createdAt: "2026-10-02T09:00:00Z"),
        ], now: later)
        #expect(setup.step == .seen)
    }

    // MARK: Detecting "seen" from session data

    @Test func seenNeedsLiveStateFromAfterTheInstall() {
        #expect(PluginSetup.seenSession(in: [session()], after: installed) == nil)
        #expect(PluginSetup.seenSession(in: [session(live: "2026-10-02T09:59:00Z")], after: installed) == nil)
        #expect(PluginSetup.seenSession(in: [session(live: "2026-10-02T10:01:00Z")], after: installed)?.id == "s1")
    }

    @Test func seenIgnoresCodexAndClosedSessionsAndPicksTheNewest() {
        let sessions = [
            session("codex", live: "2026-10-02T10:09:00Z", runtime: .codex),
            session("gone", live: "2026-10-02T10:08:00Z", state: .ended),
            session("a", live: "2026-10-02T10:02:00Z"),
            session("b", live: "2026-10-02T10:03:00Z"),
        ]
        #expect(PluginSetup.seenSession(in: sessions, after: installed)?.id == "b")
    }

    @Test func sessionsListDecodesContextLive() throws {
        let json = #"{"title":null,"goal":null,"said":null,"last_action":null,"last_action_at":null,"recent":[],"plan":null,"changes":null,"live":{"phase":"working","since":"x","last_tool":null,"last_tool_at":null,"tool_count":0,"last_event":"turn.start","last_event_at":"2026-10-02T10:01:00Z"}}"#
        let context = try JSONDecoder().decode(SessionContext.self, from: Data(json.utf8))
        #expect(context.live?.lastEventAt == "2026-10-02T10:01:00Z")
    }

    // MARK: Model: start, persistence, Done

    @Test func installStartsTheChecklistAndRemembersAnOldEntry() async {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: mcpMode)
        await runner.script(["doctor"], lines: pluginMode)
        let model = PluginOfferModel(runner: runner, defaults: freshDefaults(), clock: { installed })
        await model.refresh()
        #expect(model.setup == nil)

        await model.setPlugin(on: true)

        #expect(model.setup?.hadOldConnection == true)
        #expect(model.setup?.installedAt == installed)
        #expect(model.showsSetupCard)
        #expect(!model.showsHomeCard)
    }

    @Test func installFromNoEntryDropsTheOldConnectionRow() async {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: ["ok    Claude Code can install the Waggle plugin"])
        await runner.script(["doctor"], lines: pluginMode)
        let model = PluginOfferModel(runner: runner, defaults: freshDefaults(), clock: { installed })
        await model.refresh()
        await model.setPlugin(on: true)
        #expect(model.setup?.hadOldConnection == false)
    }

    @Test func theChecklistSurvivesARestartUntilDone() async {
        let defaults = freshDefaults()
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: mcpMode)
        await runner.script(["doctor"], lines: pluginMode)
        let model = PluginOfferModel(runner: runner, defaults: defaults, clock: { later })
        await model.refresh()
        await model.setPlugin(on: true)
        model.observe(sessions: [session(live: "2026-10-02T10:06:00Z")], cases: [])

        let reopened = PluginOfferModel(runner: FakeCommandRunner(), defaults: defaults)
        reopened.apply(checks: pluginMode.compactMap(DoctorLineParser.parse))
        #expect(reopened.setup?.step == .seen)
        #expect(reopened.showsSetupCard)

        reopened.finishSetup()
        #expect(!reopened.showsSetupCard)
        let again = PluginOfferModel(runner: FakeCommandRunner(), defaults: defaults)
        again.apply(checks: pluginMode.compactMap(DoctorLineParser.parse))
        #expect(!again.showsSetupCard)
    }

    @Test func turningThePluginOffDropsTheChecklist() async {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: mcpMode)
        await runner.script(["doctor"], lines: pluginMode)
        await runner.script(["doctor"], lines: mcpMode)
        let model = PluginOfferModel(runner: runner, defaults: freshDefaults())
        await model.refresh()
        await model.setPlugin(on: true)
        #expect(model.setup != nil)
        await model.setPlugin(on: false)
        #expect(model.setup == nil)
        #expect(!model.showsSetupCard)
    }

    @Test func aFailedInstallStartsNoChecklist() async {
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: mcpMode)
        await runner.script(["doctor"], lines: mcpMode)
        let model = PluginOfferModel(runner: runner, defaults: freshDefaults())
        await model.refresh()
        await model.setPlugin(on: true)
        #expect(model.setup == nil)
    }
}
