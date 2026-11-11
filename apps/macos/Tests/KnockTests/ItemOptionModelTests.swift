import Testing
import Foundation
@testable import Knock

/// WAG-326: an item of a request maps to the option model of a single decision, so each item reads like one.
struct ItemOptionModelTests {
    private static let compact = Option(id: "compact", label: "Compact list", title: "Compact", pros: ["Fast to scan", "Fits more"], cons: ["Less room"])
    private static let cards = Option(id: "cards", label: "Cards", title: "Cards", pros: ["Friendly"], cons: [])
    private static let table = Option(id: "table", label: "Table", title: "Table", pros: [], cons: ["Heavy"])

    private static let items = [
        Item(id: "i1", question: "Which layout?", options: [compact, cards, table], recommendation: ["cards"], recommendationWhy: "People scan cards faster."),
        Item(id: "i2", question: "Which filters?", select: .many, max: 2, options: [compact, cards, table], recommendation: ["compact", "table"], recommendationWhy: "Both are quick."),
        Item(id: "i3", question: "What should we call it?", select: .reply, recommendation: ["Flagged"], recommendationWhy: "Short."),
        Item(id: "i4", question: "Ship it?", options: [cards, table]),
    ]

    private static func request(items: [Item] = items, questions: [Question] = [], recommendation: String = "", why: String = "") -> Case {
        Case(
            id: "c1", taskId: "t", kind: .question, title: "Inbox", need: "Four decisions.", why: "Last screen.",
            recommendation: recommendation, recommendationWhy: why, options: [], status: .needsYou, hasArtifact: false,
            createdAt: "2026-10-09T10:00:00Z", updatedAt: "2026-10-09T10:00:00Z", questions: questions, items: items)
    }

    private func doc() -> QuestionsDocModel { QuestionsDocModel(request: Self.request()) }

    @Test func anItemMapsToTheSingleAskOptionModel() {
        let doc = doc()
        let question = doc.questions[0]
        let rows = doc.optionRows(question: question.id, point: question.points[0])
        #expect(rows.map(\.title) == ["Compact", "Cards", "Table"])
        #expect(rows.map(\.isRecommended) == [false, true, false])
        #expect(rows[0].pros == ["Fast to scan", "Fits more"] && rows[0].cons == ["Less room"])
        #expect(rows[1].note == "People scan cards faster." && rows[0].note == nil)
        #expect(rows.allSatisfy { $0.canDiscuss })
        #expect(rows.allSatisfy { !$0.isSelected && !$0.isLeaning && !$0.isRuledOut })
    }

    @Test func leanAndRuleOutAreExclusiveAndTakeTheirOptionsPick() {
        var doc = doc()
        let q = doc.questions[0].id, p = doc.questions[0].points[0].id
        doc.choose("Cards", question: q, point: p)
        doc.toggleLean("Cards", question: q, point: p)
        var rows = doc.optionRows(question: q, point: doc.questions[0].points[0])
        #expect(rows[1].isLeaning && !rows[1].isSelected)
        #expect(!doc.isAnswered(question: doc.questions[0], point: doc.questions[0].points[0]))
        doc.toggleRuleOut("Cards", question: q, point: p)
        rows = doc.optionRows(question: q, point: doc.questions[0].points[0])
        #expect(rows[1].isRuledOut && !rows[1].isLeaning)
        doc.toggleRuleOut("Cards", question: q, point: p)
        rows = doc.optionRows(question: q, point: doc.questions[0].points[0])
        #expect(!rows[1].isRuledOut)
        // Picking an option takes its lean back.
        doc.toggleLean("Table", question: q, point: p)
        doc.choose("Table", question: q, point: p)
        rows = doc.optionRows(question: q, point: doc.questions[0].points[0])
        #expect(rows[2].isSelected && !rows[2].isLeaning)
    }

    @Test func marksGoOutAsItemSlashOptionIdsAndSendKeepTalking() {
        var doc = doc()
        doc.toggleLean("Cards", question: doc.questions[0].id, point: doc.questions[0].points[0].id)
        doc.toggleRuleOut("Table", question: doc.questions[3].id, point: doc.questions[3].points[0].id)
        #expect(doc.leaningIds == ["i1/cards"] && doc.ruledOutIds == ["i4/table"])
        #expect(doc.sendsDiscuss && doc.canSend && !doc.sendsAnswers)
        #expect(doc.sendLabel == PromptBarLogic.keepTalkingLabel)
        #expect(doc.reviewRows[0].summary == "Leaning: Cards")
    }

    @Test func aReplyPointHasNoLeanOrRuleOut() {
        var doc = doc()
        let q = doc.questions[2]
        #expect(!q.points[0].canDiscuss)
        doc.toggleLean("Flagged", question: q.id, point: q.points[0].id)
        #expect(!doc.isDiscussing)
    }

    @Test func eachItemWithARecommendationShowsItsCardBeforeAnyPick() throws {
        let doc = doc()
        let one = try #require(doc.pointBlock(question: doc.questions[0], point: doc.questions[0].points[0]))
        #expect(one.label == "RECOMMENDED · 2" && one.title == "Cards")
        #expect(one.note == "People scan cards faster." && one.noteTitle == "Why I recommend it")
        #expect(one.pros == ["Friendly"])
        let many = try #require(doc.pointBlock(question: doc.questions[1], point: doc.questions[1].points[0]))
        #expect(many.label == "RECOMMENDED · 1 and 3" && many.title == "Compact, Table")
        let reply = try #require(doc.pointBlock(question: doc.questions[2], point: doc.questions[2].points[0]))
        #expect(reply.label == "RECOMMENDED" && reply.title == "Flagged" && reply.note == "Short.")
        // No recommendation, no pick: no card.
        #expect(doc.pointBlock(question: doc.questions[3], point: doc.questions[3].points[0]) == nil)
    }

    @Test func aPickReplacesTheRecommendationInTheCard() throws {
        var doc = doc()
        let question = doc.questions[0]
        doc.choose("Compact", question: question.id, point: question.points[0].id)
        let block = try #require(doc.pointBlock(question: question, point: question.points[0]))
        #expect(block.label == "YOUR PICK · 1" && block.title == "Compact" && block.note == nil)
        doc.choose("Cards", question: question.id, point: question.points[0].id)
        let rec = try #require(doc.pointBlock(question: question, point: question.points[0]))
        #expect(rec.label == "YOUR PICK · 2" && rec.note == "People scan cards faster.")
    }

    // MARK: Legacy questions ask

    private func legacy(recommendation: String, why: String) -> QuestionsDocModel {
        let questions = [
            Question(id: "a", title: "A?", now: nil, points: [
                QuestionPoint(id: "a1", text: "One?", options: ["Yes", "No"]), QuestionPoint(id: "a2", text: "Two?", options: ["Yes", "No"])],
                artifactRef: nil, variants: nil, variantLabel: nil),
            Question(id: "b", title: "B?", now: nil, points: [QuestionPoint(id: "b1", text: "Three?", options: ["Yes", "No"])], artifactRef: nil, variants: nil, variantLabel: nil),
        ]
        return QuestionsDocModel(request: Self.request(items: [], questions: questions, recommendation: recommendation, why: why))
    }

    @Test func aLegacyAskLevelRecommendationShowsOnceAsTheWhyOfTheFirstPoint() throws {
        let doc = legacy(recommendation: "Go with the cards.", why: "They test best.")
        let first = try #require(doc.blocks(question: doc.questions[0], point: doc.questions[0].points[0], pointNumber: 1).first)
        #expect(first.note == "Go with the cards. They test best." && first.title == nil && first.label == "RECOMMENDED")
        #expect(doc.blocks(question: doc.questions[0], point: doc.questions[0].points[1], pointNumber: 2).isEmpty)
        #expect(doc.blocks(question: doc.questions[1], point: doc.questions[1].points[0]).isEmpty)
        #expect(doc.pointBlocks(of: doc.questions[0]).count == 1 && doc.pointBlocks(of: doc.questions[1]).isEmpty)
    }

    @Test func thePageLeavesOutThePickCardOfAPickOnePoint() {
        var doc = legacy(recommendation: "Go with the cards.", why: "They test best.")
        doc.choose("Yes", question: "a", point: "a1")
        let page = doc.pageBlocks(question: doc.questions[0], point: doc.questions[0].points[0], pointNumber: 1)
        #expect(page.map(\.label) == ["RECOMMENDED"])
        doc.choose("Yes", question: "b", point: "b1")
        #expect(doc.pageBlocks(question: doc.questions[1], point: doc.questions[1].points[0]).isEmpty)
    }

    @Test func theLegacyWhyStaysAfterAPickOnTheFirstPoint() {
        var doc = legacy(recommendation: "Go with the cards.", why: "They test best.")
        doc.choose("Yes", question: "a", point: "a1")
        let blocks = doc.blocks(question: doc.questions[0], point: doc.questions[0].points[0], pointNumber: 1)
        #expect(blocks.map(\.label) == ["RECOMMENDED", "YOUR PICK · 1 · POINT 1"])
    }

    /// The daemon turns questions into items with no recommendation of their own and the ask keeps its text.
    @Test func questionsServedAsItemsKeepTheAskLevelWhyOnTheFirstItem() throws {
        let items = [
            Item(id: "a/a", question: "Layout?", options: [Self.compact, Self.cards], group: ItemGroup(id: "a", title: "Layout?")),
            Item(id: "b/b", question: "Filter?", options: [Self.compact, Self.cards], group: ItemGroup(id: "b", title: "Filter?")),
        ]
        let doc = QuestionsDocModel(request: Self.request(items: items, recommendation: "Go with cards.", why: "They test best."))
        #expect(doc.usesItems)
        let first = try #require(doc.pointBlocks(of: doc.questions[0]).first)
        #expect(first.note == "Go with cards. They test best.")
        #expect(doc.pointBlocks(of: doc.questions[1]).isEmpty)
        // An item with its own recommendation owns the why: the ask-level text is not repeated.
        let own = QuestionsDocModel(request: Self.request(recommendation: "x", why: "y"))
        #expect(own.legacyWhy == nil)
    }

    @Test func aLegacyAskWithNoRecommendationHasNoCard() {
        let doc = legacy(recommendation: "", why: "")
        #expect(doc.legacyWhy == nil)
        #expect(doc.blocks(question: doc.questions[0], point: doc.questions[0].points[0]).isEmpty)
    }

    @Test func aLegacyPointHasNoLeanOrRuleOutIcons() {
        let doc = legacy(recommendation: "x", why: "y")
        #expect(doc.optionRows(question: "a", point: doc.questions[0].points[0]).allSatisfy { !$0.canDiscuss })
    }

    @Test func oneNoteAndOnePlaceholderForOneOrMany() {
        #expect(PromptBarLogic.placeholder(.steps) == PromptBarLogic.placeholder(.decide))
        #expect(doc().nextLabel == "Next")
    }
}
