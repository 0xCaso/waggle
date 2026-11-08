import Foundation
import Testing
@testable import Knock

/// WAG-351: the artifact box shows the round on screen, plus an older artifact an option of that round links to.
@MainActor
struct WAG351Tests {
    private func rev(
        _ n: Int, _ name: String?, round: Int?, author: Revision.Author = .agent, base: Int? = nil
    ) -> Revision {
        Revision(
            id: "r\(n)", caseId: "c1", n: n, createdAt: "2026-10-10T10:00:00Z", author: author, baseRevision: base,
            name: name, kind: .markdown, round: round)
    }

    /// Round 0 sends Brief and Flow. Round 1 sends Flow v2. Round 2 sends Deck and Notes. Round 3 sends nothing.
    private var revisions: [Revision] {
        [
            rev(1, "Brief", round: 0), rev(2, "Flow", round: 0), rev(3, "Flow", round: 1),
            rev(4, "Deck", round: 2), rev(5, "Notes", round: 2),
        ]
    }

    private func titles(_ tabs: [ArtifactTab]) -> [String] { tabs.map(\.title) }

    @Test func eachRoundShowsTheArtifactsItSent() {
        #expect(titles(ArtifactTabs.tabs(revisions: revisions, round: 0, shown: 2)) == ["Brief", "Flow"])
        let one = ArtifactTabs.tabs(revisions: revisions, round: 1, shown: 3)
        #expect(titles(one) == ["Flow"] && one.first?.revision == 3 && one.first?.revisions == [2, 3])
        #expect(titles(ArtifactTabs.tabs(revisions: revisions, round: 2, shown: 5)) == ["Deck", "Notes"])
    }

    @Test func anEarlierRoundShowsEachTabAsOfThatRound() {
        let zero = ArtifactTabs.tabs(revisions: revisions, round: 0, shown: 2)
        #expect(zero.map(\.revision) == [1, 2])
        #expect(zero[1].revisions == [2])
    }

    @Test func anOptionLinkKeepsAnOlderArtifactInTheSet() {
        let tabs = ArtifactTabs.tabs(revisions: revisions, round: 2, refs: [" brief "], shown: 5)
        #expect(titles(tabs) == ["Brief", "Deck", "Notes"])
        #expect(tabs[0].revision == 1)
        // The link still selects its tab.
        let option = Option(id: "a", label: "A", artifactRef: "Brief")
        #expect(ArtifactTabs.link(for: option, in: tabs, current: nil)?.tabId == tabs[0].id)
    }

    @Test func aRoundWithNoArtifactShowsTheOneItShows() {
        #expect(titles(ArtifactTabs.tabs(revisions: revisions, round: 3, shown: 5)) == ["Notes"])
        #expect(titles(ArtifactTabs.tabs(revisions: revisions, round: 3, shown: nil)) == ["Notes"])
        #expect(titles(ArtifactTabs.tabs(revisions: revisions, round: 3, shown: 3)) == ["Flow"])
    }

    @Test func aRevisionByYouStaysWithItsArtifact() {
        let all = revisions + [rev(6, nil, round: 2, author: .you, base: 3)]
        let tabs = ArtifactTabs.tabs(revisions: all, round: 2, refs: ["Flow"], shown: 5)
        #expect(titles(tabs) == ["Flow", "Deck", "Notes"])
        #expect(tabs[0].revision == 6 && tabs[0].revisions == [2, 3, 6])
        // Without a link the edit does not make Flow a tab of round 2: the agent sent it in round 1.
        #expect(titles(ArtifactTabs.tabs(revisions: all, round: 2, shown: 5)) == ["Deck", "Notes"])
    }

    @Test func noRoundFieldKeepsEveryTab() {
        let old = revisions.map { rev($0.n, $0.name, round: nil) }
        #expect(ArtifactTabs.tabs(revisions: old, round: 2, shown: 5) == ArtifactTabs.tabs(revisions: old))
        #expect(ArtifactTabs.tabs(revisions: revisions, round: nil) == ArtifactTabs.tabs(revisions: revisions))
    }

    @Test func theRoundDecodesAndAnOldRevisionHasNone() throws {
        let json = #"{"id":"r1","case_id":"c1","n":1,"created_at":"x","author":"agent","round":3}"#
        #expect(try JSONDecoder().decode(Revision.self, from: Data(json.utf8)).round == 3)
        let old = #"{"id":"r1","case_id":"c1","n":1,"created_at":"x","author":"agent"}"#
        #expect(try JSONDecoder().decode(Revision.self, from: Data(old.utf8)).round == nil)
    }

    // MARK: detail

    private func planRound(_ seq: Int, shown: Int?, refs: [String] = []) -> PlanRound {
        PlanRound(
            seq: seq, stage: PlanStage(name: .questions, step: 1, total: 3, totalIsEstimate: true), question: "Q",
            options: refs.map { Option(id: $0, label: $0, artifactRef: $0) }, recommendation: "",
            createdAt: "2026-10-10T10:00:00Z", revision: shown)
    }

    private func detail(plan: Bool, rounds: [PlanRound]) -> CaseDetail {
        let info = PlanInfo(
            stage: PlanStage(name: .questions, step: 1, total: 3, totalIsEstimate: true), rounds: rounds.count, answered: 0)
        let c = Case(
            id: "c1", taskId: "t1", kind: .question, title: "T", need: "N", why: "W", recommendation: "",
            recommendationWhy: "", options: [], status: .needsYou, hasArtifact: true,
            createdAt: "2026-10-10T10:00:00Z", updatedAt: "2026-10-10T10:00:00Z", plan: plan ? info : nil)
        return CaseDetail(
            case: c, task: KnockTask(id: "t1", name: "n", project: "p"), messages: [], revisions: revisions,
            comments: [], replies: [], planRounds: rounds)
    }

    @Test func aPlanShowsTheNewestRoundAndAnEarlierRoundWhenRead() {
        let rounds = [planRound(0, shown: 2), planRound(1, shown: 3), planRound(2, shown: 5, refs: ["Brief"])]
        let d = detail(plan: true, rounds: rounds)
        #expect(titles(d.artifactTabs()) == ["Brief", "Deck", "Notes"])
        #expect(titles(d.artifactTabs(viewing: 3)) == ["Flow"])
        #expect(titles(d.artifactTabs(viewing: 1)) == ["Brief", "Flow"])
    }

    @Test func aCaseWithOneRoundShowsEveryArtifact() {
        let all = ["Brief", "Flow", "Deck", "Notes"]
        // WAG-382: a case that is not a plan filters by round too, so it is not the "all" case any more.
        #expect(titles(detail(plan: false, rounds: []).artifactTabs()) == ["Deck", "Notes"])
        #expect(titles(detail(plan: true, rounds: [planRound(0, shown: 5)]).artifactTabs()) == all)
    }

    @Test func goingBackToTheNewestRoundRestoresItsSet() {
        let rounds = [planRound(0, shown: 2), planRound(1, shown: 3), planRound(2, shown: 5)]
        let d = detail(plan: true, rounds: rounds)
        let newest = d.artifactTabs()
        #expect(titles(d.artifactTabs(viewing: 1)) == ["Brief", "Flow"])
        #expect(d.artifactTabs(viewing: nil) == newest && titles(newest) == ["Deck", "Notes"])
    }

    @Test func aTabThatLeavesTheSetFallsToTheFirstTab() {
        let rounds = [planRound(0, shown: 2), planRound(1, shown: 3), planRound(2, shown: 5)]
        let d = detail(plan: true, rounds: rounds)
        let m = LiveArtifactModel(
            caseId: "c1", client: KnockClient(socketPath: "/nonexistent.sock", startDaemon: {}),
            tabs: d.artifactTabs(viewing: 1))
        m.select(m.tabs[1].id)
        m.update(tabs: d.artifactTabs(viewing: 3))
        #expect(m.selectedTab?.title == "Flow")
    }
}
