import Testing
import Foundation
@testable import Knock

/// WAG-317 (spec 7.3, 7.4 and risk R1): the case and reply JSON survives the three blocks update in both
/// directions.
///
/// - The new app decodes every case and reply the 0.2.21 daemon served (`golden-0.2.21.json`).
/// - The 0.2.21 app models (`V0221`, a copy in this test target) decode every case and reply the new daemon
///   serves (`served-three-blocks.json`), old shapes and canonical ones. The closed enums `Case.Kind`,
///   `ReplyIntent` and `Select` make this fail on a value the old app does not know.
///
/// Both files are in `daemon/test/fixtures/compat/`. The daemon test `compat-old-agents.test.ts` keeps
/// them current.
struct LegacyDecodeTests {
    typealias Json = [String: Any]

    static func fixture(_ name: String) throws -> [String: [Json]] {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        url.appendPathComponent("daemon/test/fixtures/compat/\(name)")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? Json)
        return try #require(root["scenarios"] as? [String: [Json]])
    }

    static func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

    /// Decodes the case detail of every step and the reply of every reply step. Returns how many of each.
    static func decodeAll<D: Decodable, R: Decodable>(
        _ file: String, detail: D.Type, reply: R.Type, each: (String, Int, D) throws -> Void = { _, _, _ in }
    ) throws -> (details: Int, replies: Int) {
        var details = 0
        var replies = 0
        for (name, steps) in try fixture(file).sorted(by: { $0.key < $1.key }) {
            for (index, step) in steps.enumerated() {
                let decoded = try JSONDecoder().decode(D.self, from: data(try #require(step["detail"])))
                try each(name, index, decoded)
                details += 1
                if let raw = step["reply"] {
                    _ = try JSONDecoder().decode(R.self, from: data(raw))
                    replies += 1
                }
            }
        }
        return (details, replies)
    }

    // MARK: new app, 0.2.21 daemon

    @Test func theNewAppDecodesEveryCaseAndReplyThe0221DaemonServed() throws {
        let counts = try Self.decodeAll("golden-0.2.21.json", detail: CaseDetail.self, reply: Reply.self)
        #expect(counts.details >= 30)
        #expect(counts.replies >= 15)
    }

    @Test func oldCasesKeepTheirMeaningInTheNewModels() throws {
        _ = try Self.decodeAll("golden-0.2.21.json", detail: CaseDetail.self, reply: Reply.self) { name, _, detail in
            #expect(detail.case.items.isEmpty || detail.case.kind == .question || detail.case.kind == .review, "\(name)")
            if name == "select-many" { #expect(detail.case.select == .many && detail.case.max == 2) }
            if name == "questions" { #expect(detail.case.questions.count == 2) }
            if name == "plan-stages" { #expect(detail.case.plan != nil) }
            if name == "question-options" { #expect(detail.case.options.map(\.id) == ["a", "b"] && detail.case.recommendation == "a") }
        }
        let steps = try Self.fixture("golden-0.2.21.json")
        let replies = steps.values.flatMap { $0 }.compactMap { $0["reply"] }
        let intents = try replies.map { try JSONDecoder().decode(Reply.self, from: Self.data($0)).intent }
        #expect(Set(intents.map(\.rawValue)) == ["decision", "more_detail", "discuss"])
    }

    @Test func aStoredReplyOfEveryOldShapeDecodesWithItsFields() throws {
        let steps = try Self.fixture("golden-0.2.21.json")
        func reply(_ scenario: String, _ index: Int) throws -> Reply {
            let raw = try #require(steps[scenario]?[index]["reply"])
            return try JSONDecoder().decode(Reply.self, from: Self.data(raw))
        }
        #expect(try reply("question-options", 1).choice == "a")
        #expect(try reply("select-many", 1).choices == ["x", "z"])
        #expect(try reply("more-detail-diagram", 1).format == .diagram)
        let discuss = try reply("discuss-lean-and-rule-out", 1)
        #expect(discuss.leaning == ["a"] && discuss.ruledOut == ["c"])
        #expect(try reply("questions", 1).answers?.count == 3)
    }

    // MARK: 0.2.21 app, new daemon

    @Test func the0221ModelsDecodeEveryCaseAndReplyTheNewDaemonServes() throws {
        let counts = try Self.decodeAll("served-three-blocks.json", detail: V0221.CaseDetail.self, reply: V0221.Reply.self)
        #expect(counts.details >= 45)
        #expect(counts.replies >= 22)
    }

    @Test func theNewDaemonNeverSendsAValueTheOldEnumsDoNotKnow() throws {
        var kinds = Set<String>()
        var intents = Set<String>()
        var selects = Set<String>()
        for steps in try Self.fixture("served-three-blocks.json").values {
            for step in steps {
                let detail = try JSONDecoder().decode(V0221.CaseDetail.self, from: Self.data(try #require(step["detail"])))
                kinds.insert(detail.case.kind.rawValue)
                selects.insert(detail.case.select.rawValue)
                for reply in detail.replies { intents.insert(reply.intent.rawValue) }
            }
        }
        #expect(kinds.isSubset(of: ["question", "review"]))
        #expect(intents.isSubset(of: ["decision", "more_detail", "discuss"]))
        #expect(selects.isSubset(of: ["one", "many"]))
        #expect(kinds == ["question", "review"])
    }

    @Test func aSingleItemAskReadsInTheOldAppLikeASingleDecision() throws {
        let steps = try Self.fixture("served-three-blocks.json")
        let ask = try #require(steps["items-one-with-stage"]?.first)
        let old = try JSONDecoder().decode(V0221.CaseDetail.self, from: Self.data(try #require(ask["detail"])))
        #expect(old.case.options.map(\.id) == ["a", "b"])
        #expect(old.case.recommendation == "a")
        #expect(old.case.questions.isEmpty)
        #expect(old.case.plan?.stage.name == .approaches)
        // The same bytes decode in the new app with the item next to the old fields.
        let new = try JSONDecoder().decode(CaseDetail.self, from: Self.data(try #require(ask["detail"])))
        #expect(new.case.items.map(\.id) == ["layout"])
    }

    @Test func aReviewKeepsItsOldShapeInTheOldApp() throws {
        let steps = try Self.fixture("served-three-blocks.json")
        let ask = try #require(steps["review-approve"]?.first)
        let old = try JSONDecoder().decode(V0221.CaseDetail.self, from: Self.data(try #require(ask["detail"])))
        #expect(old.case.kind == .review)
        #expect(old.case.options.map(\.id) == ["approve", "request_changes"])
    }

    @Test func aManyItemAskDegradesToQuestionsForTheOldApp() throws {
        let steps = try Self.fixture("served-three-blocks.json")
        let ask = try #require(steps["items-three-kinds"]?.first)
        let old = try JSONDecoder().decode(V0221.CaseDetail.self, from: Self.data(try #require(ask["detail"])))
        #expect(old.case.options.isEmpty)
        #expect(old.case.questions.count == 3)
        #expect(old.case.questions.allSatisfy { $0.points.count == 1 })
        let new = try JSONDecoder().decode(CaseDetail.self, from: Self.data(try #require(ask["detail"])))
        #expect(new.case.items.map(\.id) == ["layout", "areas", "free"])
        #expect(new.case.items.map(\.select) == [.one, .many, .reply])
    }

    @Test func aNewReplyFieldDoesNotBreakTheOldReplyModel() throws {
        let steps = try Self.fixture("served-three-blocks.json")
        let raw = try #require(steps["items-three-kinds"]?[3]["reply"] as? Json)
        #expect(raw["item_answers"] != nil && raw["outcome"] as? String == "decide")
        let old = try JSONDecoder().decode(V0221.Reply.self, from: Self.data(raw))
        #expect(old.intent == .decision)
        let talk = try #require(steps["items-three-kinds"]?[2]["reply"] as? Json)
        #expect(talk["outcome"] as? String == "talk")
        _ = try JSONDecoder().decode(V0221.Reply.self, from: Self.data(talk))
    }
}
