import Testing
import Foundation
@testable import Knock

/// WAG-360: an option carries up to 3 effect lines, shown as "If you pick this".
struct WAG360EffectsTests {
    private static let withEffects = Option(
        id: "a", label: "One page", title: "One page", pros: ["Fast"], cons: ["Long"],
        effects: ["Touches the form", "Closes the steps"])
    private static let plain = Option(id: "b", label: "Steps", title: "Steps", pros: ["Short"])

    @Test func decodesWithAndWithoutEffects() throws {
        let with = try JSONDecoder().decode(Option.self, from: Data(#"{"id":"a","label":"A","effects":["x","y"]}"#.utf8))
        #expect(with.effects == ["x", "y"])
        let without = try JSONDecoder().decode(Option.self, from: Data(#"{"id":"a","label":"A"}"#.utf8))
        #expect(without.effects.isEmpty)
        // An option without effects goes out without the key.
        let out = String(decoding: try JSONEncoder().encode(without), as: UTF8.self)
        #expect(!out.contains("effects"))
        #expect(try JSONDecoder().decode(Option.self, from: JSONEncoder().encode(with)).effects == ["x", "y"])
    }

    @Test func aPointOptionKeepsEffects() throws {
        let point = try JSONDecoder().decode(PointOption.self, from: Data(#"{"label":"A","effects":["x"]}"#.utf8))
        #expect(point.effects == ["x"] && point.hasPoints)
        let back = try JSONDecoder().decode(PointOption.self, from: JSONEncoder().encode(point))
        #expect(back.effects == ["x"])
    }

    @Test func effectsCountInTheRestOfAClosedCard() {
        #expect(CalmOption.teaser(pros: ["a"], cons: ["b"], effects: ["x", "y", "z"])?.more == 3)
        #expect(CalmOption.effectsTitle == "If you pick this")
    }

    @Test func aRowWithEffectsOnlyStillOpensItsTooltip() {
        #expect(CompactOptionRow.hasTip(description: nil, pros: [], cons: [], effects: ["x"], note: nil))
        #expect(!CompactOptionRow.hasTip(description: nil, pros: [], cons: [], effects: [], note: nil))
    }

    @Test func theEffectPartHasPlainWords() {
        #expect(AskTextPart.effect.words == "an effect")
        #expect(AskTextPart.effect.rawValue == "effect")
    }

    @Test func linesOfAnEffectKeepTheirOffsets() {
        #expect(AskTextContent.lineBases(["abc", "de"]) == [0, 4])
    }

    @Test func theMarkedTextsOfARoundIncludeEffects() throws {
        let json = #"{"seq":0,"created_at":"2026-10-10T10:00:00Z","question":"Q","items":[{"id":"i1","question":"Which?","options":[{"id":"a","label":"A","effects":["Closes the steps"]}]}]}"#
        let round = try JSONDecoder().decode(Round.self, from: Data(json.utf8))
        #expect(round.markedTexts.contains("Closes the steps"))
    }

    @Test func aPointBlockPassesTheEffects() throws {
        let item = Item(id: "i1", question: "Which?", options: [Self.withEffects, Self.plain], recommendation: ["a"], recommendationWhy: "Why.")
        let request = Case(
            id: "c1", taskId: "t", kind: .question, title: "T", need: "N", why: "W", recommendation: "", recommendationWhy: "",
            options: [], status: .needsYou, hasArtifact: false, createdAt: "2026-10-10T10:00:00Z",
            updatedAt: "2026-10-10T10:00:00Z", questions: [],
            items: [item, Item(id: "i2", question: "Ship it?", options: [Self.plain])])
        var doc = QuestionsDocModel(request: request)
        let question = doc.questions[0]
        let point = question.points[0]
        #expect(doc.optionRows(question: question.id, point: point)[0].effects == ["Touches the form", "Closes the steps"])
        #expect(doc.optionRows(question: question.id, point: point)[1].effects.isEmpty)
        let recommended = try #require(doc.pointBlock(question: question, point: point))
        #expect(recommended.effects == ["Touches the form", "Closes the steps"])
        doc.choose("Steps", question: question.id, point: point.id)
        #expect(try #require(doc.pointBlock(question: question, point: point)).effects.isEmpty)
    }

    @Test func thePickBlockOfASingleAskCarriesTheOption() throws {
        let block = try #require(CalmOption.pickBlock(options: [Self.withEffects, Self.plain], selectedId: "a", recommendationId: nil))
        #expect(block.option.effects.count == 2)
    }
}
