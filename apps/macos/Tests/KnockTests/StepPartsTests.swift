import Testing
import Foundation
@testable import Knock

/// WAG-334: a step uses the pick-several list, the keys and the cards of a single request.
@MainActor
struct StepPartsTests {
    private static let a = Option(id: "a", label: "A")
    private static let b = Option(id: "b", label: "B")
    private static let c = Option(id: "c", label: "C")

    private static let items = [
        Item(id: "one", question: "Which layout?", options: [a, b, c], recommendation: ["b"], recommendationWhy: "Scans fast."),
        Item(id: "many", question: "Which filters?", select: .many, max: 2, options: [a, b, c], recommendation: ["a", "c"], recommendationWhy: "Both are quick."),
    ]

    private static func request(status: CaseStatus = .needsYou) -> Case {
        Case(
            id: "c1", taskId: "t", kind: .question, title: "Inbox", need: "Two decisions.", why: "Last screen.",
            recommendation: "", recommendationWhy: "", options: [], status: status, hasArtifact: false,
            createdAt: "2026-10-09T10:00:00Z", updatedAt: "2026-10-09T10:00:00Z", questions: [], items: items)
    }

    private func doc() -> QuestionsDocModel { QuestionsDocModel(request: Self.request()) }

    // MARK: Pick several

    @Test func tickRecommendedTicksTheRecommendedAndClearTakesThemBack() {
        var doc = doc()
        let q = doc.questions[1].id, p = doc.questions[1].points[0]
        #expect(doc.canTickRecommended(p, question: q))
        doc.tickRecommended(question: q, point: p.id)
        #expect(doc.draft(q, p.id).choices == ["A", "C"])
        #expect(!doc.canTickRecommended(p, question: q))
        doc.clearTicks(question: q, point: p.id)
        #expect(doc.draft(q, p.id).choices.isEmpty && doc.canTickRecommended(p, question: q))
    }

    @Test func atTheLimitUntickedRowsDimAndDoNotToggle() {
        var doc = doc()
        let question = doc.questions[1], p = question.points[0]
        doc.choose("A", question: question.id, point: p.id)
        doc.choose("B", question: question.id, point: p.id)
        #expect(doc.isAtLimit(p, doc.draft(question.id, p.id)))
        let rows = doc.optionRows(question: question.id, point: p)
        #expect(rows.map(\.isLimitDimmed) == [false, false, true])
        doc.choose("C", question: question.id, point: p.id)
        #expect(doc.draft(question.id, p.id).choices == ["A", "B"])
    }

    @Test func theManyCardGoesAfterTheFirstTick() {
        var doc = doc()
        let question = doc.questions[1], p = question.points[0]
        #expect(doc.pointBlock(question: question, point: p)?.label == "RECOMMENDED · 1 and 3")
        doc.choose("B", question: question.id, point: p.id)
        #expect(doc.pointBlock(question: question, point: p) == nil)
    }

    @Test func aSingleRequestShowsTheManyCardUntilATick() {
        let options = [Self.a, Self.b, Self.c]
        let card = DecisionPickBlockView.manyCard(
            options: options, recommendations: ["a", "c"], why: "Both are quick.", hasPick: false, isLocked: false)
        #expect(card?.label == "RECOMMENDED · 1 and 3" && card?.title == "A, C" && card?.note == "Both are quick.")
        #expect(DecisionPickBlockView.manyCard(options: options, recommendations: ["a"], why: "", hasPick: true, isLocked: false) == nil)
        #expect(DecisionPickBlockView.manyCard(options: options, recommendations: ["a"], why: "", hasPick: false, isLocked: true) == nil)
        #expect(DecisionPickBlockView.manyCard(options: options, recommendations: [], why: "", hasPick: false, isLocked: false) == nil)
        #expect(DecisionPickBlockView.manyCard(options: options, recommendations: ["a"], why: "", hasPick: false, isLocked: false)?.note == nil)
    }

    // MARK: Keys

    @Test func theNumberKeysPickOnTheCurrentStep() {
        var doc = doc()
        doc.pick(position: 2)
        #expect(doc.draft(doc.questions[0].id, "one").choice == "B")
        // A key past the rows does nothing.
        doc.pick(position: 9)
        #expect(doc.draft(doc.questions[0].id, "one").choice == "B")
        doc.next()
        doc.pick(position: 1); doc.pick(position: 3)
        #expect(doc.draft(doc.questions[1].id, "many").choices == ["A", "C"])
    }

    @Test func commandDTakesTheRecommendationAndSendsNothing() {
        var doc = doc()
        doc.acceptRecommendation()
        #expect(doc.draft(doc.questions[0].id, "one").choice == "B")
        doc.acceptRecommendation()
        #expect(doc.draft(doc.questions[0].id, "one").choice == "B")
        doc.next()
        doc.acceptRecommendation()
        #expect(doc.draft(doc.questions[1].id, "many").choices == ["A", "C"])
        #expect(!doc.isLocked && doc.step == 1)
    }

    @Test func keysDoNothingOnTheReviewStepOrOnceSent() {
        var doc = doc()
        doc.jump(to: doc.reviewStep)
        doc.pick(position: 1); doc.acceptRecommendation()
        #expect(doc.answeredCount == 0 && doc.keyPoint == nil)
    }

    // MARK: Step parts

    @Test func theNeedShowsOnEveryQuestionStep() {
        var doc = doc()
        #expect(doc.showsDocNeed)
        doc.next()
        #expect(doc.showsDocNeed)
    }

    @Test func aLegacyCardUsesTheSameLabelAsTheOthers() throws {
        let questions = [
            Question(id: "a", title: "A?", now: nil, points: [QuestionPoint(id: "a1", text: "A?", options: ["Yes", "No"])], artifactRef: nil, variants: nil, variantLabel: nil),
            Question(id: "b", title: "B?", now: nil, points: [QuestionPoint(id: "b1", text: "B?", options: ["Yes", "No"])], artifactRef: nil, variants: nil, variantLabel: nil),
        ]
        var request = Self.request()
        request = Case(
            id: "c1", taskId: "t", kind: .question, title: "Inbox", need: "n", why: "w",
            recommendation: "Go with yes.", recommendationWhy: "It is safe.", options: [], status: .needsYou, hasArtifact: false,
            createdAt: "2026-10-09T10:00:00Z", updatedAt: "2026-10-09T10:00:00Z", questions: questions, items: [])
        let doc = QuestionsDocModel(request: request)
        let block = try #require(doc.blocks(question: doc.questions[0], point: doc.questions[0].points[0]).first)
        #expect(block.noteTitle == "Why I recommend it")
    }
}
