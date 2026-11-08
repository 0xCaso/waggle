import Foundation
import Testing
@testable import Knock

/// WAG-338: the getting started list, "Your agent is on it", the tour triggers, saving and migration.
@MainActor
struct GettingStartedTests {
    private let now = FirstRun.now
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// A model on a temp file, plus a second one over the same file to prove what was saved.
    private func make(isOnboarded: Bool = false) -> (model: GettingStartedModel, reload: () -> GettingStartedModel, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("waggle-gs-\(UUID().uuidString)")
        let env = ["KNOCK_HOME": root.path]
        let store = GettingStartedStore(environment: env, isOnboarded: { isOnboarded }, now: { [start] in start })
        return (GettingStartedModel(store: store), { GettingStartedModel(store: store) }, root)
    }

    private func created(_ offset: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: start.addingTimeInterval(offset))
    }

    // MARK: The six lines

    @Test func sixLinesInOrderAndNoneDoneAtFirst() {
        let (model, _, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(model.items.map(\.line) == [.connect, .job, .decision, .talk, .notifications, .designKit])
        #expect(model.items.map(\.title) == [
            "Connect an agent", "Send your agent a first job", "Get your first decision", "Keep talking once",
            "Allow notifications", "Add a design kit",
        ])
        #expect(model.doneCount == 0)
        #expect(model.isListVisible)
        #expect(model.items.compactMap(\.actionLabel) == ["Allow", "Add"])
    }

    @Test func everyLineExplainsItself() {
        let (model, _, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(model.items.allSatisfy { !$0.hint.isEmpty })
        #expect(model.items.allSatisfy { !$0.hint.contains("\u{2014}") && !$0.title.contains("\u{2014}") })
    }

    @Test func connectAndJobTickWhenTheyHappenAndTheHintsSayWhat() {
        let (model, _, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        model.markConnected(agent: "Claude Code")
        model.markJobSent(project: "Acme support", agent: "Claude Code", summary: AgentOnIt.defaultSummary, at: now)
        #expect(model.isDone(.connect) && model.isDone(.job))
        #expect(model.items[0].hint == "Claude Code is connected.")
        #expect(model.items[1].hint == "Sent to Acme support. Click to send another.")
        #expect(model.fraction == 2.0 / 6.0)
    }

    @Test func decisionAndKeepTalkingTickFromTheAsksAndOnlyFromAsksAfterFirstRunBegan() {
        let (model, _, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        // History from before first run: ignored.
        model.apply(cases: [FirstRun.ask("old", status: .waitingOnAgent, at: "2020-01-01T00:00:00.000Z", replyId: "r0", intent: .decision)])
        #expect(!model.isDone(.decision))
        model.apply(cases: [FirstRun.ask("talk", status: .waitingOnAgent, at: created(10), replyId: "r1", intent: .discuss)])
        #expect(model.isDone(.talk))
        #expect(!model.isDone(.decision), "a keep-talking reply is not a decision")
        model.apply(cases: [FirstRun.ask("dec", status: .waitingOnAgent, at: created(20), replyId: "r2", intent: .decision)])
        #expect(model.isDone(.decision))
    }

    @Test func notificationsTickOnlyWhenAllowedAndAreHighlightedAfterTheFirstDecision() {
        let (model, _, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        model.updateNotifications(.notAsked)
        model.updateNotifications(.off)
        #expect(!model.isDone(.notifications))
        #expect(!model.highlightsNotifications)
        model.apply(cases: [FirstRun.ask("dec", status: .waitingOnAgent, at: created(10), replyId: "r", intent: .decision)])
        #expect(model.highlightsNotifications)
        model.updateNotifications(.on)
        #expect(model.isDone(.notifications))
        #expect(!model.highlightsNotifications)
    }

    @Test func theNotificationsTipSaysThatMacOSAsksOnlyOnAllow() {
        #expect(GettingStartedModel.notificationsTipTitle == "Next: hear when an agent needs you")
        #expect(GettingStartedModel.notificationsTipBody == "Allow notifications from the list. macOS asks for permission only when you press Allow.")
    }

    @Test func theSystemPermissionIsAskedOnlyWhenTheAllowButtonIsPressed() {
        let (model, _, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        var asked = 0
        model.onRequestNotifications = { asked += 1 }
        model.updateNotifications(.notAsked)
        model.apply(cases: [])
        model.markConnected(agent: "Claude Code")
        #expect(asked == 0, "nothing in onboarding asks macOS by itself")
        model.open(.notifications)
        #expect(asked == 1)
    }

    @Test func designKitTicksWhenAKitIsSet() {
        let (model, _, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        model.updateDesignKit(isSet: false)
        #expect(!model.isDone(.designKit))
        model.updateDesignKit(isSet: true)
        #expect(model.isDone(.designKit))
    }

    @Test func eachLineOpensItsPlace() {
        let (model, _, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        var opened: [String] = []
        model.onOpenAgents = { opened.append("agents") }
        model.onOpenJobPicker = { opened.append("picker") }
        model.onOpenDesignKit = { opened.append("kit") }
        model.onRequestNotifications = { opened.append("allow") }
        model.apply(cases: [FirstRun.ask("c1", at: created(5))])
        model.onOpenCase = { opened.append("case:\($0)") }
        for line in GettingStartedLine.allCases { model.open(line) }
        #expect(opened == ["agents", "picker", "case:c1", "case:c1", "allow", "kit"])
    }

    // MARK: Hide, Help, done

    @Test func hideHidesAndTheHelpMenuBringsItBack() {
        let (model, _, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        model.hide()
        #expect(!model.isListVisible)
        model.show()
        #expect(model.isListVisible)
    }

    @Test func theListHidesItselfWhenEveryLineIsDoneAndHelpStillBringsItBack() {
        let (model, _, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        model.markConnected(agent: "Claude Code")
        model.markJobSent(project: "P", agent: "Claude Code", summary: "s", at: start.addingTimeInterval(1))
        model.apply(cases: [
            FirstRun.ask("a", status: .waitingOnAgent, at: created(10), replyId: "r1", intent: .discuss),
            FirstRun.ask("b", status: .waitingOnAgent, at: created(11), replyId: "r2", intent: .decision),
        ])
        model.updateNotifications(.on)
        #expect(model.isListVisible)
        model.updateDesignKit(isSet: true)
        #expect(model.doneCount == 6)
        #expect(!model.isListVisible)
        model.show()
        #expect(model.isListVisible)
    }

    // MARK: Saving

    @Test func theStateSurvivesARestart() {
        let (model, reload, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        model.markConnected(agent: "Codex")
        model.markJobSent(project: "Acme support", agent: "Claude Code", summary: "finding a real decision", at: now)
        model.updateNotifications(.on)
        model.hide()
        let again = reload()
        #expect(again.isDone(.connect) && again.isDone(.job) && again.isDone(.notifications))
        #expect(again.state.connectedAgent == "Codex")
        #expect(again.state.hidden)
        #expect(again.agentOnIt?.projectName == "Acme support")
    }

    @Test func aLaterBuildCanAddAFieldWithoutResettingTheState() throws {
        let (model, _, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        model.markConnected(agent: "Codex")
        let url = OnboardingState.gettingStartedURL(environment: ["KNOCK_HOME": root.path])
        let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\"tourSkipped\"", with: "\"someFutureField\" : 1,\n  \"tourSkipped\"")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let store = GettingStartedStore(environment: ["KNOCK_HOME": root.path], isOnboarded: { false }, now: { Date() })
        #expect(store.load().connected)
        // An older file with fewer keys still loads.
        try #"{"startedAt":"2026-10-09T10:00:00Z","connected":true}"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(store.load().connected)
        #expect(!store.load().hidden)
    }

    // MARK: Migration of the old onboarding state

    @Test func aPersonWhoFinishedTheOldSetupNeverSeesTheNewOne() {
        let (model, reload, root) = make(isOnboarded: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!model.isListVisible)
        #expect(model.agentOnIt == nil)
        #expect(model.state.tourSkipped && model.state.tourStarted)
        // A new ask never starts the tour for them.
        model.apply(cases: [FirstRun.ask("fresh", at: created(100))])
        #expect(!model.tour.isActive)
        // The migration is written once: a later launch reads the same state.
        #expect(!reload().isListVisible)
    }

    @Test func aFreshInstallIsNotMigratedEvenAfterStepOneWritesTheMarker() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("waggle-gs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let env = ["KNOCK_HOME": root.path]
        let first = GettingStartedModel(store: GettingStartedStore(environment: env, now: { Date() }))
        #expect(first.isListVisible)
        OnboardingState.markOnboarded(environment: env)
        let second = GettingStartedModel(store: GettingStartedStore(environment: env, now: { Date() }))
        #expect(second.isListVisible, "the marker made in step 1 must not turn a new person into a migrated one")
    }

    @Test func reopeningSetupFromSettingsStillWorksForAMigratedPerson() async {
        let (gs, _, root) = make(isOnboarded: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeCommandRunner()
        await runner.script(["doctor"], lines: ["ok    claude found", "ok    Claude Code MCP server registered"])
        let fakes = OnboardingFakes()
        fakes.isOnboarded = true
        fakes.sessions = [FirstRun.session("open", project: "acme-support")]
        let model = makeOnboardingModel(runner: runner, fakes: fakes, gettingStarted: gs)
        model.reset()
        _ = try? await pollUntil(.seconds(10), { model.connectSucceeded })
        model.continueFromConnect()
        #expect(model.screen == .firstJob)
        await model.loadFirstJobData()
        await model.startFirstJob()
        // They get "Your agent is on it" for the job they send; the list stays as they left it.
        #expect(gs.agentOnIt != nil)
        #expect(!gs.isListVisible)
    }

    // MARK: Your agent is on it

    @Test func theAgentIsOnItFromTheJobUntilTheFirstAskArrives() {
        let (model, _, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(model.agentOnIt == nil)
        model.markJobSent(project: "Acme support", agent: "Claude Code", summary: AgentOnIt.defaultSummary, at: start)
        #expect(model.agentOnIt != nil)
        // An ask from before the job does not end the wait.
        model.apply(cases: [FirstRun.ask("early", at: created(-60))])
        #expect(model.agentOnIt != nil)
        model.apply(cases: [FirstRun.ask("first", at: created(30))])
        #expect(model.agentOnIt == nil)
    }

    @Test func theSampleIsOfferedOnlyAfterThreeMinutes() {
        let working = AgentOnIt(projectName: "Acme support", since: start, agent: "Claude Code", summary: AgentOnIt.defaultSummary)
        #expect(!working.sampleOffered(now: start.addingTimeInterval(179)))
        #expect(working.sampleOffered(now: start.addingTimeInterval(180)))
        #expect(working.minutes(now: start.addingTimeInterval(125)) == 2)
        #expect(working.queueLine(now: start.addingTimeInterval(125)) == "Acme support · finding a real decision · 2 min")
    }

    @Test func theWorkingCardSaysWhatTheAgentDoes() {
        let find = AgentOnIt(projectName: "Acme support", since: start, agent: "Claude Code", summary: AgentOnIt.defaultSummary)
        #expect(find.cardText == "Claude Code is looking at Acme support for one real open decision. It will bring options with a prototype or a write-up each. The ask opens here.")
        let own = AgentOnIt(projectName: "Acme support", since: start, agent: "Your agent", summary: "Which queue library?")
        #expect(own.cardText.hasPrefix("Your agent is working on \"Which queue library?\" in Acme support."))
    }

    // MARK: Tour triggers

    @Test func theTourStartsOnTheFirstRealAskAndOpensIt() {
        let (model, _, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        var opened: [String] = []
        model.onOpenCase = { opened.append($0) }
        model.apply(cases: [FirstRun.ask("first", at: created(30))])
        #expect(model.tour.activeCaseId == "first")
        #expect(model.tour.currentMark == .artifact)
        #expect(opened == ["first"])
        // Once: a second ask does not restart it.
        model.tour.skip()
        model.apply(cases: [FirstRun.ask("first", at: created(30)), FirstRun.ask("second", at: created(60))])
        #expect(!model.tour.isActive)
        #expect(opened == ["first"])
    }

    @Test func theTourNeverStartsOnAskFromBeforeFirstRun() {
        let (model, _, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        model.apply(cases: [FirstRun.ask("history", at: "2020-01-01T00:00:00.000Z")])
        #expect(!model.tour.isActive)
        #expect(model.state.tourStarted == false)
    }

    @Test func theSampleAskStartsTheTourLikeARealOne() {
        let (model, _, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        model.markJobSent(project: "Acme support", agent: "Claude Code", summary: "s", at: start)
        model.apply(cases: [FirstRun.ask("sample", title: SampleAsk.title, at: created(200))])
        #expect(model.tour.currentMark == .artifact)
        #expect(model.agentOnIt == nil)
    }

    @Test func markThreeShowsWhenTheAgentComesBackWithANewRoundAfterKeepTalking() {
        let (model, _, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        model.apply(cases: [FirstRun.ask("c", at: created(30))])
        model.tour.next()
        model.tour.next()   // marks 1 and 2 done
        #expect(!model.tour.isActive)
        // The person keeps talking: the case waits on the agent. No mark yet.
        model.apply(cases: [FirstRun.ask("c", status: .waitingOnAgent, at: created(30), replyId: "r1", intent: .discuss)])
        #expect(!model.tour.isActive)
        // The agent comes back with round 2.
        model.apply(cases: [FirstRun.ask("c", at: created(30), replyId: "r1", intent: .discuss, seq: 1, roundQuestion: "Drawer or strip?")])
        #expect(model.tour.currentMark == .round)
        #expect(model.tour.activeCaseId == "c")
        model.tour.next()
        #expect(!model.tour.isActive)
        #expect(model.state.tourRoundDone)
        // Shown once.
        model.apply(cases: [FirstRun.ask("c", at: created(30), replyId: "r1", intent: .discuss, seq: 1, roundQuestion: "Drawer or strip?")])
        #expect(!model.tour.isActive)
    }

    @Test func aSkippedTourNeverShowsMarkThree() {
        let (model, _, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        model.apply(cases: [FirstRun.ask("c", at: created(30))])
        model.tour.skip()
        #expect(model.state.tourSkipped)
        model.apply(cases: [FirstRun.ask("c", at: created(30), replyId: "r1", intent: .discuss, seq: 1, roundQuestion: "Q?")])
        #expect(!model.tour.isActive)
    }

    @Test func theTourStateIsSavedSoItNeverRepeatsAfterARestart() {
        let (model, reload, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        model.apply(cases: [FirstRun.ask("c", at: created(30))])
        let again = reload()
        again.apply(cases: [FirstRun.ask("c", at: created(30))])
        #expect(!again.tour.isActive, "the tour began once and is not started again")
    }
}

/// The three marks and how a run ends.
@MainActor
struct CoachMarkTourModelTests {
    @Test func theThreeMarksCarryTheCopyOfTheApprovedPrototype() {
        #expect(CoachMarkTourModel.Mark.allCases.map(\.title) == ["What the agent brings", "Decide or keep talking", "A new round"])
        #expect(CoachMarkTourModel.Mark.artifact.body == "Each option comes with its own prototype or write-up. Click the tabs to compare them.")
        #expect(CoachMarkTourModel.Mark.options.body == "Pick an option and press Decide. Not sure? Lean ◐, rule out ×, or ask: the agent answers in a new round.")
        #expect(CoachMarkTourModel.Mark.round.body == "You kept talking, so the agent came back with a new round. Every round stays in your history.")
        #expect(CoachMarkTourModel.Mark.allCases.map(\.counterLabel) == ["1 of 3", "2 of 3", "3 of 3"])
        #expect(CoachMarkTourModel.Mark.allCases.map(\.buttonLabel) == ["Next", "Got it", "Got it"])
    }

    @Test func startsAtMarkOneForTheGivenCase() {
        let tour = CoachMarkTourModel()
        tour.start(caseId: "c_1")
        #expect(tour.isActive)
        #expect(tour.activeCaseId == "c_1")
        #expect(tour.currentMark == .artifact)
    }

    @Test func nextWalksMarkOneThenMarkTwoThenEnds() {
        let tour = CoachMarkTourModel()
        var ended: [CoachMarkTourModel.EndReason] = []
        tour.onEnd = { ended.append($0) }
        tour.start(caseId: "c_1")
        tour.next()
        #expect(tour.currentMark == .options)
        #expect(ended.isEmpty)
        tour.next()
        #expect(!tour.isActive)
        #expect(tour.currentMark == nil)
        #expect(ended == [.completed(.options)])
    }

    @Test func markThreeRunsAloneAndEndsOnItsOwnButton() {
        let tour = CoachMarkTourModel()
        var ended: [CoachMarkTourModel.EndReason] = []
        tour.onEnd = { ended.append($0) }
        tour.startRound(caseId: "c_1")
        #expect(tour.currentMark == .round)
        #expect(tour.isShowingRound(for: "c_1"))
        #expect(!tour.isShowingRound(for: "other"))
        tour.next()
        #expect(ended == [.completed(.round)])
    }

    @Test func skipEndsTheTourImmediatelyFromAnyMark() {
        let tour = CoachMarkTourModel()
        var ended: [CoachMarkTourModel.EndReason] = []
        tour.onEnd = { ended.append($0) }
        tour.start(caseId: "c_1")
        tour.next()
        tour.skip()
        #expect(!tour.isActive)
        #expect(ended == [.skipped])
        tour.skip()
        #expect(ended == [.skipped], "a second skip says nothing")
    }

    @Test func startingAgainOnASecondCaseResetsCleanly() {
        let tour = CoachMarkTourModel()
        tour.start(caseId: "c_1")
        tour.next()
        tour.start(caseId: "c_2")
        #expect(tour.activeCaseId == "c_2")
        #expect(tour.currentMark == .artifact)
    }

    /// Wide: artifact left, title and options right. Narrow: artifact above the title, options at the bottom.
    private static let size = CGSize(width: CoachMarkOverlayView.bubbleWidth, height: CoachMarkOverlayView.bubbleHeight)
    private static let frames: [(name: String, container: CGSize, artifact: CGRect, title: CGRect, options: CGRect)] = [
        ("wide", CGSize(width: 1440, height: 860),
         CGRect(x: 416, y: 60, width: 520, height: 780), CGRect(x: 960, y: 60, width: 440, height: 90), CGRect(x: 950, y: 560, width: 460, height: 280)),
        ("narrow", CGSize(width: 900, height: 760),
         CGRect(x: 420, y: 60, width: 460, height: 300), CGRect(x: 420, y: 380, width: 460, height: 80), CGRect(x: 410, y: 560, width: 480, height: 190)),
    ]

    @Test func eachMarkStaysInsideTheWindowAndOffTheTargetTitleAndComposer() {
        for f in Self.frames {
            let cases: [(String, CGRect, [CGRect])] = [
                ("artifact", f.artifact, [f.title, f.options]),
                ("options", f.options, [f.title]),
                ("round", f.title, [f.options]),
            ]
            for (mark, target, avoid) in cases {
                let placed = CoachMarkOverlayView.placement(target: target, avoid: avoid, container: f.container, size: Self.size)
                let frame = CGRect(origin: placed.origin, size: Self.size)
                let window = CGRect(origin: .zero, size: f.container).insetBy(dx: 12, dy: 12)
                #expect(window.contains(frame), "\(f.name) \(mark) stays inside with 12 pt margin")
                for rect in [target] + avoid {
                    #expect(!frame.intersects(rect), "\(f.name) \(mark) clear of \(rect)")
                }
            }
        }
    }

    /// WAG-343: in the wide window mark 1 must not sit over the queue column. The artifact box is wide, the
    /// title and options fill the right, so the old order fell back to the left, over the person's queue row.
    @Test func theQueueColumnIsTheLastChoice() {
        let f = Self.frames[0]
        let queue = CGRect(x: 0, y: 0, width: 392, height: f.container.height)
        // The old placement over the queue (the evidence of 9 Oct).
        let old = CoachMarkOverlayView.placement(target: f.artifact, avoid: [f.title, f.options], container: f.container, size: Self.size)
        #expect(CGRect(origin: old.origin, size: Self.size).intersects(queue))
        for (target, avoid) in [(f.artifact, [f.title, f.options]), (f.options, [f.title]), (f.title, [f.options])] {
            let placed = CoachMarkOverlayView.placement(target: target, avoid: avoid, container: f.container, queue: queue, size: Self.size)
            #expect(!CGRect(origin: placed.origin, size: Self.size).intersects(queue))
        }
        let artifact = CoachMarkOverlayView.placement(target: f.artifact, avoid: [f.title, f.options], container: f.container, queue: queue, size: Self.size)
        #expect(artifact.side == .inside)
        for avoid in [[f.title, f.options]] {
            #expect(!CGRect(origin: artifact.origin, size: Self.size).intersects(avoid[0]))
        }
    }

    @Test func theSideFollowsTheFirstFreePlaceBelowThenAboveThenSide() {
        let container = CGSize(width: 1000, height: 700)
        let below = CoachMarkOverlayView.placement(target: CGRect(x: 640, y: 100, width: 300, height: 80), avoid: [], container: container, size: Self.size)
        #expect(below.side == .below && below.origin.y == 194)
        let above = CoachMarkOverlayView.placement(target: CGRect(x: 640, y: 560, width: 300, height: 120), avoid: [], container: container, size: Self.size)
        #expect(above.side == .above && above.origin.y + Self.size.height < 560)
        let beside = CoachMarkOverlayView.placement(target: CGRect(x: 100, y: 12, width: 300, height: 676), avoid: [], container: container, size: Self.size)
        #expect(beside.side == .right)
        let farRight = CoachMarkOverlayView.placement(target: CGRect(x: 950, y: 100, width: 40, height: 40), avoid: [], container: container, size: Self.size)
        #expect(farRight.origin.x + Self.size.width <= container.width - 12)
    }
}
