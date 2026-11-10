import Foundation
import Testing
@testable import Knock

/// HAIL-151: a plan ask is one case that walks the brainstorming stages. The wire keeps `kind`
/// "question" and adds `plan`, so an app that does not know plans shows a question.
@MainActor
struct PlanAskTests {
    private static let options = [Option(id: "a", label: "One", title: "One"), Option(id: "b", label: "Two", title: "Two")]

    private static func planCase(
        stage: PlanStage = PlanStage(name: .questions, step: 3, total: 5, totalIsEstimate: true),
        rounds: Int = 3, answered: Int = 2, createdAt: String = "2026-10-03T09:00:00Z",
        updatedAt: String = "2026-10-03T09:12:00Z"
    ) -> Case {
        Case(
            id: "c_plan", taskId: "t1", kind: .question, title: "Brainstorm: weekly posts", need: "First question",
            why: "Because", recommendation: "a", recommendationWhy: "Safe", options: options, status: .needsYou,
            hasArtifact: true, createdAt: createdAt, updatedAt: updatedAt,
            plan: PlanInfo(stage: stage, rounds: rounds, answered: answered))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private static let caseJSON = #"""
    {"id":"c_1","task_id":"t_1","kind":"question","title":"Plan","need":"Q","why":"W",
     "recommendation":"a","recommendation_why":"R","options":[{"id":"a","label":"One"}],
     "status":"needs_you","has_artifact":false,"runtime":"claude",
     "created_at":"2026-10-03T10:00:00Z","updated_at":"2026-10-03T10:00:00Z",
     "plan":{"stage":{"name":"design","step":1,"total":3},"rounds":4,"answered":3}}
    """#

    // MARK: protocol

    @Test func decodesAPlanCase() throws {
        let value = try decode(Case.self, Self.caseJSON)
        #expect(value.kind == .question)
        #expect(value.plan == PlanInfo(stage: PlanStage(name: .design, step: 1, total: 3), rounds: 4, answered: 3))
    }

    @Test func aCaseWithoutPlanDecodesWithNone() throws {
        let cut = try #require(Self.caseJSON.range(of: #""plan":"#))
        let head = String(Self.caseJSON[..<cut.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let json = String(head.dropLast()) + "}"
        #expect(try decode(Case.self, json).plan == nil)
    }

    /// A stage name this app does not know must leave a plain question, never a decoding failure.
    @Test func anUnknownStageFallsBackToAPlainQuestion() throws {
        let json = Self.caseJSON.replacingOccurrences(of: #""name":"design""#, with: #""name":"polish""#)
        let value = try decode(Case.self, json)
        #expect(value.plan == nil)
        #expect(value.id == "c_1")
    }

    @Test func aPlanCaseRoundTrips() throws {
        let data = try JSONEncoder().encode(Self.planCase())
        #expect(try JSONDecoder().decode(Case.self, from: data) == Self.planCase())
    }

    @Test func decodesPlanRoundsOfACaseDetail() throws {
        let json = #"""
        {"case":\#(Self.caseJSON),
         "task":{"id":"t_1","name":"n","project":"p"},
         "messages":[],"revisions":[],"comments":[],"replies":[],
         "plan_rounds":[{"seq":0,"stage":{"name":"questions","step":1,"total":5,"total_is_estimate":true},
                         "question":"Who?","options":[{"id":"a","label":"One"}],"recommendation":"a",
                         "recommendation_why":"R","created_at":"2026-10-03T10:00:00Z",
                         "answer":{"choice":"a","created_at":"2026-10-03T10:01:00Z"}},
                        {"seq":1,"stage":{"name":"design"},"question":"Right?","options":[],"recommendation":"a",
                         "recommendation_why":"","created_at":"2026-10-03T10:02:00Z","answer":null}]}
        """#
        let detail = try decode(CaseDetail.self, json)
        let rounds = try #require(detail.planRounds)
        #expect(rounds.count == 2)
        #expect(rounds[0].stage.totalIsEstimate == true)
        #expect(rounds[0].answer?.choice == "a")
        #expect(rounds[1].answer == nil)
    }

    @Test func aCaseDetailWithoutRoundsHasNone() throws {
        let json = #"""
        {"case":\#(Self.caseJSON),"task":{"id":"t_1","name":"n","project":"p"},
         "messages":[],"revisions":[],"comments":[],"replies":[]}
        """#
        #expect(try decode(CaseDetail.self, json).planRounds == nil)
    }

    // MARK: queue row text

    @Test func theProgressLabel() {
        #expect(PlanText.progressLabel(PlanStage(name: .questions, step: 3, total: 5, totalIsEstimate: true)) == "Question 3 of ~5")
        #expect(PlanText.progressLabel(PlanStage(name: .design, step: 1, total: 3)) == "Design · section 1 of 3")
    }

    @Test func theTrackLightsTheCurrentStageAndTicksTheDoneOnes() {
        let states = PlanText.track(current: .design).map(\.state)
        #expect(states == [.done, .done, .current, .upcoming])
        #expect(PlanText.track(current: .questions).map(\.state) == [.current, .upcoming, .upcoming, .upcoming])
        #expect(PlanText.track(current: .spec).map(\.state) == [.done, .done, .done, .current])
        #expect(PlanText.track(current: .spec).map { PlanText.title($0.name) } == ["Questions", "Approaches", "Design", "Spec"])
    }

    // MARK: buttons

    @Test func primaryButtonCopyPerStage() {
        #expect(PlanText.primaryLabel(.questions) == "Next question")
        #expect(PlanText.primaryLabel(.approaches) == "Use this approach")
        #expect(PlanText.primaryLabel(.design) == "Approve section")
        #expect(PlanText.primaryLabel(.spec) == "Approve and start planning")
        // The short words for a row too narrow for the full label.
        #expect(PlanText.shortPrimaryLabel(.questions) == "Next")
        #expect(PlanText.shortPrimaryLabel(.approaches) == "Use this")
        #expect(PlanText.shortPrimaryLabel(.design) == "Approve")
        #expect(PlanText.shortPrimaryLabel(.spec) == "Approve")
        #expect(PlanText.secondaryLabel(.design) == "Change")
        #expect(PlanText.secondaryLabel(.spec) == "Request changes")
        #expect(PlanText.secondaryLabel(.questions) == nil)
        #expect(PlanText.secondaryLabel(.approaches) == nil)
    }

    @Test func theSendPillUsesThePlanWords() {
        #expect(PromptBarLogic.sendPillLabel(commentCount: 0, planLabel: "Next question") == "Next question")
        #expect(PromptBarLogic.sendPillLabel(commentCount: 2, planLabel: "Approve section") == "Approve section + 2 comments")
        #expect(PromptBarLogic.sendPillLabel(commentCount: 0) == nil)
    }

    @Test func aChangeRequestIsWordedForTheAgent() {
        #expect(PlanText.changeMessage(stage: .design, note: "Rename it").hasPrefix("Change requested to this section:"))
        #expect(PlanText.changeMessage(stage: .spec, note: "Add a risk").hasPrefix("Changes requested to the spec:"))
    }

    // MARK: composer

    @Test func aPlanRoundStartsWithNothingPicked() {
        let composer = ComposerViewModel(knockCase: Self.planCase())
        #expect(composer.selectedOptionId == nil)
        #expect(composer.planPrimaryLabel == "Next question")
        #expect(composer.planSecondaryLabel == nil)
    }

    @Test func aNewRoundStartsWithNothingPicked() {
        let composer = ComposerViewModel(knockCase: Self.planCase())
        composer.selectOption("b")
        let next = Case(
            id: "c_plan", taskId: "t1", kind: .question, title: "Brainstorm: weekly posts", need: "First question",
            why: "Because", recommendation: "y", recommendationWhy: "Short",
            options: [Option(id: "x", label: "X"), Option(id: "y", label: "Y")], status: .needsYou, hasArtifact: true,
            createdAt: "2026-10-03T09:00:00Z", updatedAt: "2026-10-03T09:20:00Z",
            plan: PlanInfo(stage: PlanStage(name: .approaches), rounds: 4, answered: 3))
        composer.refresh(next)
        #expect(composer.selectedOptionId == nil)
        #expect(composer.planPrimaryLabel == "Use this approach")
    }

    @Test func anOrdinaryQuestionStillStartsWithNothingPicked() {
        let plain = Case(
            id: "c2", taskId: "t1", kind: .question, title: "T", need: "N", why: "W", recommendation: "a",
            recommendationWhy: "R", options: Self.options, status: .needsYou, hasArtifact: false,
            createdAt: "2026-10-03T09:00:00Z", updatedAt: "2026-10-03T09:00:00Z")
        let composer = ComposerViewModel(knockCase: plain)
        #expect(composer.selectedOptionId == nil)
        #expect(composer.planPrimaryLabel == nil)
    }

    @Test func theDesignRoundHasASecondButton() {
        let composer = ComposerViewModel(
            knockCase: Self.planCase(stage: PlanStage(name: .design, step: 1, total: 3)))
        #expect(composer.planSecondaryLabel == "Change")
    }

    // MARK: rounds, sorting, layout

    @Test func earlierAnsweredRoundsFoldAway() {
        func round(_ seq: Int, answered: Bool) -> PlanRound {
            PlanRound(
                seq: seq, stage: PlanStage(name: .questions, step: seq + 1), question: "Q\(seq)", options: Self.options,
                recommendation: "a", createdAt: "2026-10-03T09:0\(seq):00Z",
                answer: answered ? PlanAnswer(choice: "b", createdAt: "2026-10-03T09:0\(seq):30Z") : nil)
        }
        let rounds = [round(0, answered: true), round(1, answered: true), round(2, answered: false)]
        let earlier = PlanText.earlierAnswered(rounds)
        #expect(earlier.map(\.seq) == [0, 1])
        #expect(PlanText.answeredLabel(earlier.count) == "2 answered")
        #expect(PlanText.answerSummary(earlier[0]) == "Two")
        #expect(PlanText.currentQuestion(for: Self.planCase(), rounds: rounds) == "Q2")
        #expect(PlanText.currentQuestion(for: Self.planCase(), rounds: nil) == "First question")
    }

    @Test func aPlanSortsByItsLatestRound() {
        let plan = Self.planCase(createdAt: "2026-10-03T08:00:00Z", updatedAt: "2026-10-03T11:00:00Z")
        let other = Case(
            id: "c_other", taskId: "t1", kind: .question, title: "T", need: "N", why: "W", recommendation: "a",
            recommendationWhy: "R", options: Self.options, status: .needsYou, hasArtifact: false,
            createdAt: "2026-10-03T10:00:00Z", updatedAt: "2026-10-03T10:00:00Z")
        #expect(AppModel.newestFirst([other, plan]).map(\.id) == ["c_plan", "c_other"])
        let older = Self.planCase(createdAt: "2026-10-03T08:00:00Z", updatedAt: "2026-10-03T08:30:00Z")
        #expect(AppModel.newestFirst([older, other]).map(\.id) == ["c_other", "c_plan"])
    }


    @Test func trackFormNarrowsWithWidth() {
        for style in [PlanTrackLayout.Style.numbered, .chips] {
            for stage in PlanStageName.allCases {
                let full = PlanTrackLayout.requiredWidth(.full, style: style, stage: stage)
                let circles = PlanTrackLayout.requiredWidth(.circles, style: style, stage: stage)
                #expect(full > circles)
                #expect(PlanTrackLayout.form(width: full, style: style, stage: stage) == .full)
                #expect(PlanTrackLayout.form(width: full - 1, style: style, stage: stage) == .circles)
                #expect(PlanTrackLayout.form(width: circles - 1, style: style, stage: stage) == .line)
                #expect(PlanTrackLayout.form(width: 0, style: style, stage: stage) == .line)
                #expect(PlanTrackLayout.form(width: 10_000, style: style, stage: stage) == .full)
            }
        }
    }

    // MARK: question headline and body (operator, 4 Oct)

    @Test func markersInTheHeadlineStayWholeAndTheSplitSkipsCodeAndBold() {
        #expect(AgentMarkdown.singleLine("**Use SQLite?** It is local.") == "Use SQLite? It is local.")
    }

    @Test func trackLineSaysStageOfFour() {
        #expect(PlanTrackLayout.line(.approaches) == "Stage 2 of 4 · Approaches")
        #expect(PlanTrackLayout.line(.spec) == "Stage 4 of 4 · Spec")
    }
}
