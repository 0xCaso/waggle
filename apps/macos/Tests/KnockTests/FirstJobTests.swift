import Foundation
import Testing
@testable import Knock

/// WAG-338: the project row, the suggestions, the prompt and the choice of session. All pure.
@MainActor
struct FirstJobTests {
    private let now = FirstRun.now
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    // MARK: Projects

    @Test func projectsComeFromSessionsNewestFirstWithSomethingElseLast() {
        let sessions = [
            FirstRun.session("a", project: "billing-api", runtime: .codex, state: .ended, seen: "2026-10-08T10:00:00.000Z"),
            FirstRun.session("b", project: "acme-support", seen: "2026-10-09T11:00:00.000Z"),
            FirstRun.session("c", project: "notes-app", state: .ended, seen: "2026-10-06T10:00:00.000Z"),
        ]
        let projects = OnboardingProjects.build(sessions: sessions, now: now)
        #expect(projects.map(\.name) == ["Acme support", "Billing api", "Notes app", "Something else"])
        #expect(projects.last?.isSomethingElse == true)
        #expect(projects.last?.detail == "Pick a folder")
        #expect(projects[0].detail == "Claude Code · open now")
        #expect(projects[1].detail.hasPrefix("Codex · "))
        #expect(projects[0].folder == "/Users/me/acme-support")
    }

    @Test func projectsLeaveOutSessionsWithoutAFolderAndTheSampleFolder() {
        let sessions = [
            FirstRun.session("a", project: "Claude app", cwd: ""),
            FirstRun.session("b", project: "Waggle", cwd: "/tmp/knock-test-ask-AB12/Waggle"),
            FirstRun.session("c", project: "real-app"),
        ]
        #expect(OnboardingProjects.build(sessions: sessions, now: now).map(\.name) == ["Real app", "Something else"])
    }

    @Test func oneTileForManySessionsOfOneProjectAndAtMostThreeProjects() {
        let sessions = [
            FirstRun.session("a1", project: "alpha", seen: "2026-10-09T11:00:00.000Z"),
            FirstRun.session("a2", project: "Alpha", seen: "2026-10-09T10:00:00.000Z"),
            FirstRun.session("b", project: "beta", seen: "2026-10-09T09:00:00.000Z"),
            FirstRun.session("c", project: "gamma", seen: "2026-10-09T08:00:00.000Z"),
            FirstRun.session("d", project: "delta", seen: "2026-10-09T07:00:00.000Z"),
        ]
        let projects = OnboardingProjects.build(sessions: sessions, now: now)
        #expect(projects.map(\.name) == ["Alpha", "Beta", "Gamma", "Something else"])
    }

    @Test func noSessionsLeavesOnlySomethingElse() {
        #expect(OnboardingProjects.build(sessions: [], now: now) == [.somethingElse])
    }

    @Test func aFolderPickedByHandShowsItsNameNotItsPath() {
        let project = OnboardingProject.picked(folder: URL(fileURLWithPath: "/Users/me/work/fragrant-hospital-fc8f1973"))
        #expect(project.name == "Fragrant hospital")
        #expect(project.folder == "/Users/me/work/fragrant-hospital-fc8f1973")
        #expect(!project.name.contains("/"))
    }

    // MARK: Suggestions

    private var acme: OnboardingProject {
        OnboardingProjects.build(sessions: [FirstRun.session("s", project: "acme-support")], now: now)[0]
    }

    @Test func suggestionsComeFromSessionTitlesAndPastAsksNewestFirst() {
        let sessions = [FirstRun.session("s", project: "acme-support", title: "Flagged conversations", seen: "2026-10-08T10:00:00.000Z")]
        let cases = [
            FirstRun.ask("c1", title: "Export: sync or async?", at: "2026-10-02T10:00:00.000Z"),
            FirstRun.ask("c2", project: "other-app", title: "Not this project", at: "2026-10-09T10:00:00.000Z"),
        ]
        let suggestions = FirstJobSuggestions.build(project: acme, sessions: sessions, cases: cases, now: now)
        #expect(suggestions.map(\.title) == ["Flagged conversations", "Export: sync or async?"])
        #expect(suggestions[0].source == "From your session yesterday.")
        #expect(suggestions[1].source == "From your decision last week.")
    }

    @Test func withNoHistoryThereAreNoSuggestions() {
        #expect(FirstJobSuggestions.build(project: acme, sessions: [FirstRun.session("s", project: "acme-support")], cases: [], now: now).isEmpty)
    }

    @Test func atMostThreeSuggestionsWithoutRepeatsOrCodeLookingTitles() {
        let sessions = [
            FirstRun.session("s1", project: "acme-support", title: "story/WAG-338", seen: "2026-10-09T11:00:00.000Z"),
            FirstRun.session("s2", project: "acme-support", title: "knock-waggle-xza23H", seen: "2026-10-09T10:00:00.000Z"),
        ]
        let cases = (1...5).map { FirstRun.ask("c\($0)", title: "Ask number \($0)", at: "2026-10-0\($0)T10:00:00.000Z") }
            + [FirstRun.ask("dup", title: "ask number 5", at: "2026-10-05T09:00:00.000Z")]
        let suggestions = FirstJobSuggestions.build(project: acme, sessions: sessions, cases: cases, now: now)
        #expect(suggestions.count == 3)
        #expect(suggestions.map(\.title) == ["Ask number 5", "Ask number 4", "Ask number 3"])
    }

    @Test func theSampleAskIsNeverSuggested() {
        let cases = [FirstRun.ask("c", title: SampleAsk.title)]
        #expect(FirstJobSuggestions.build(project: acme, sessions: [], cases: cases, now: now).isEmpty)
    }

    /// The brief: never Claude Code transcripts or ~/.claude. A session's `context` (the daemon reads it from
    /// a transcript) must not feed a suggestion.
    @Test func neverUsesTheTranscriptFieldsOfASession() {
        let context = SessionContext(title: "Transcript title here", goal: "Transcript goal", said: "Transcript said", plan: nil)
        let sessions = [FirstRun.session("s", project: "acme-support", context: context)]
        #expect(FirstJobSuggestions.build(project: acme, sessions: sessions, cases: [], now: now).isEmpty)
    }

    @Test func aFolderPickedByHandFindsHistoryByItsName() {
        let picked = OnboardingProject.picked(folder: URL(fileURLWithPath: "/Users/me/acme-support"))
        let cases = [FirstRun.ask("c", title: "Pricing page layout")]
        #expect(FirstJobSuggestions.build(project: picked, sessions: [], cases: cases, now: now).map(\.title) == ["Pricing page layout"])
    }

    @Test func timeWords() {
        let d = { (s: String) in KnockDateFormat.date(from: s)! }
        #expect(FirstJobWords.since(d("2026-10-09T08:00:00.000Z"), now: now, sentence: true, calendar: utc) == "earlier today")
        #expect(FirstJobWords.since(d("2026-10-09T08:00:00.000Z"), now: now, calendar: utc) == "today")
        #expect(FirstJobWords.since(d("2026-10-08T23:00:00.000Z"), now: now, calendar: utc) == "yesterday")
        #expect(FirstJobWords.since(d("2026-10-06T10:00:00.000Z"), now: now, calendar: utc) == "3 days ago")
        #expect(FirstJobWords.since(d("2026-10-01T10:00:00.000Z"), now: now, calendar: utc) == "last week")
        #expect(FirstJobWords.since(d("2026-09-18T10:00:00.000Z"), now: now, calendar: utc) == "3 weeks ago")
        #expect(FirstJobWords.since(.distantPast, now: now, calendar: utc) == "a while ago")
    }

    // MARK: Prompt

    @Test func theDefaultPromptTellsTheAgentToFindOneRealDecisionAndScoutOptions() {
        let prompt = FirstJobPrompt.build(.findDecision, projectName: "Acme support")
        #expect(prompt.contains("Acme support"))
        for word in ["recent commits", "open TODOs", "one real open decision", "2 or 3 options", "prototype or a write-up", "waggle_ask", "pick and why"] {
            #expect(prompt.contains(word), "missing: \(word)")
        }
        #expect(!prompt.contains("\u{2014}"))
    }

    @Test func aSuggestionAndAnOwnJobCarryTheirTextAndTheSameClosing() {
        let suggestion = FirstJobSuggestion(title: "Flagged conversations", source: "From your session yesterday.")
        let fromSuggestion = FirstJobPrompt.build(.suggestion(suggestion), projectName: "Acme support")
        #expect(fromSuggestion.contains("Flagged conversations"))
        #expect(fromSuggestion.hasSuffix(FirstJobPrompt.closing))
        let own = FirstJobPrompt.build(.own("  Which queue library?  "), projectName: "Acme support")
        #expect(own.contains("Which queue library?"))
        #expect(!own.contains("  Which"))
        #expect(own.hasSuffix(FirstJobPrompt.closing))
    }

    @Test func summariesForTheWorkingCard() {
        #expect(FirstJobPrompt.summary(.findDecision) == "finding a real decision")
        #expect(FirstJobPrompt.summary(.own(" Pick a queue ")) == "Pick a queue")
    }

    // MARK: Open session detection and routing

    private func routing(_ sessions: [SessionInfo], project: String = "acme-support") -> FirstJobRouting {
        let projects = OnboardingProjects.build(sessions: sessions + [FirstRun.session("keep", project: project, state: .ended)], now: now)
        return FirstJobRouting.make(project: projects.first { $0.name == ProjectName.display(project: project) }!, sessions: sessions)
    }

    @Test func anOpenClaudeSessionInTheProjectIsTheFirstRoute() {
        let r = routing([FirstRun.session("open", project: "acme-support")])
        guard case .session(let choice) = r.current else { Issue.record("expected a session"); return }
        #expect(choice.sessionId == "open")
        #expect(choice.agentName == "Claude Code")
        #expect(r.startLabel == "Send to my session")
        #expect(r.canChange)
    }

    @Test func theLineNamesTheSessionBeforeAnythingIsSent() {
        let r = routing([FirstRun.session("open", project: "acme-support", started: "2026-10-09T10:12:00.000Z")])
        let line = r.line(projectName: "Acme support", calendar: utc)
        #expect(line == "Sends to your open Claude Code session in Acme support (started 10:12).")
    }

    @Test func onlyLiveClaudeSessionsWithTheWayToWakeThemCount() {
        let r = routing([
            FirstRun.session("codex", project: "acme-support", runtime: .codex),
            FirstRun.session("ended", project: "acme-support", state: .ended),
            FirstRun.session("deaf", project: "acme-support", canNudge: false),
            FirstRun.session("other", project: "billing-api"),
        ])
        #expect(r.current == .terminal)
        #expect(r.startLabel == "Start in Terminal")
        #expect(!r.canChange)
        #expect(r.line(projectName: "Acme support") == "No open session in Acme support. Waggle starts Claude Code in Terminal with the prompt in it.")
    }

    @Test func changeStepsThroughOpenSessionsThenTerminalAndBack() {
        var r = routing([
            FirstRun.session("old", project: "acme-support", seen: "2026-10-09T08:00:00.000Z"),
            FirstRun.session("new", project: "acme-support", seen: "2026-10-09T11:00:00.000Z"),
        ])
        func id(_ r: FirstJobRouting) -> String {
            if case .session(let c) = r.current { return c.sessionId }
            return "terminal"
        }
        #expect(id(r) == "new")
        r.change()
        #expect(id(r) == "old")
        r.change()
        #expect(id(r) == "terminal")
        #expect(r.line(projectName: "Acme support").hasPrefix("Waggle starts a new Claude Code session"))
        r.change()
        #expect(id(r) == "new")
    }

    @Test func aFolderPickedByHandMatchesASessionInThatFolder() {
        let sessions = [FirstRun.session("open", project: "weird-tag", cwd: "/Users/me/elsewhere")]
        let picked = OnboardingProject.picked(folder: URL(fileURLWithPath: "/Users/me/elsewhere"))
        #expect(FirstJobRouting.make(project: picked, sessions: sessions).usesOpenSession)
    }
}
