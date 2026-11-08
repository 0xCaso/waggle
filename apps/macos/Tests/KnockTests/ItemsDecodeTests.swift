import Testing
import Foundation
@testable import Knock

/// WAG-315: the app reads items, groups, item answers, outcome and rounds. The golden file is the daemon's
/// own (`daemon/test/fixtures/items-golden.json`, WAG-312): every `expect.items` decodes, every reply
/// fixture decodes, and an old payload with no items still decodes as before.
struct ItemsDecodeTests {
    /// The golden file, read from the repository (the test runs from a checkout).
    static func golden() throws -> [String: Any] {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        url.appendPathComponent("daemon/test/fixtures/items-golden.json")
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

    static func caseJSON(items: Any? = nil, extra: [String: Any] = [:]) -> [String: Any] {
        var json: [String: Any] = [
            "id": "c1", "task_id": "t1", "kind": "question", "title": "T", "need": "N", "why": "W",
            "recommendation": "", "recommendation_why": "", "options": [], "status": "needs_you", "has_artifact": false,
            "created_at": "2026-10-08T10:00:00Z", "updated_at": "2026-10-08T10:00:00Z",
        ]
        if let items { json["items"] = items }
        for (key, value) in extra { json[key] = value }
        return json
    }

    @Test func everyGoldenAskDecodesItsItems() throws {
        let asks = try #require(Self.golden()["asks"] as? [[String: Any]])
        #expect(asks.count >= 14)
        for ask in asks {
            let expect = try #require(ask["expect"] as? [String: Any])
            let raw = try #require(expect["items"] as? [[String: Any]])
            let items = try JSONDecoder().decode([Item].self, from: Self.data(raw))
            #expect(items.map(\.id) == raw.map { $0["id"] as! String }, "\(ask["name"] ?? "")")
            for (item, source) in zip(items, raw) {
                #expect(item.select.rawValue == source["select"] as? String)
                #expect(item.options.count == (source["options"] as? [Any])?.count)
            }
            // The same items inside a case.
            let decoded = try JSONDecoder().decode(Case.self, from: Self.data(Self.caseJSON(items: raw)))
            #expect(decoded.items == items)
        }
    }

    @Test func goldenGroupsAndRecommendationsDecode() throws {
        let asks = try #require(Self.golden()["asks"] as? [[String: Any]])
        let questions = try #require(asks.first { $0["name"] as? String == "questions-to-groups" })
        let items = try JSONDecoder().decode([Item].self, from: Self.data((questions["expect"] as! [String: Any])["items"]!))
        #expect(items.map(\.id) == ["q1/p1", "q1/p2", "q2/p1"])
        #expect(items.map { $0.group?.id } == ["q1", "q1", "q2"])
        #expect(items[0].options.map(\.id) == ["o1", "o2"])

        let many = try #require(asks.first { $0["name"] as? String == "options-many" })
        let manyItems = try JSONDecoder().decode([Item].self, from: Self.data((many["expect"] as! [String: Any])["items"]!))
        #expect(manyItems[0].select == .many && manyItems[0].max != nil)
        #expect(manyItems[0].recommendation.count >= 1)

        // A single recommendation id and a list both read as a list.
        let one = try JSONDecoder().decode(Item.self, from: Data(#"{"id":"m","select":"one","options":[{"id":"a","label":"A"}],"recommendation":"a"}"#.utf8))
        #expect(one.recommendation == ["a"])
        let reply = try #require(asks.first { $0["name"] as? String == "reply-only" })
        let replyItems = try JSONDecoder().decode([Item].self, from: Self.data((reply["expect"] as! [String: Any])["items"]!))
        #expect(replyItems[0].select == .reply && replyItems[0].options.isEmpty && replyItems[0].recommendation.count == 1)
    }

    @Test func goldenUpdatesDecodeTheirItems() throws {
        let updates = try #require(Self.golden()["updates"] as? [[String: Any]])
        var seen = 0
        for update in updates {
            guard let raw = (update["expect"] as? [String: Any])?["items"] else { continue }
            _ = try JSONDecoder().decode([Item].self, from: Self.data(raw))
            seen += 1
        }
        #expect(seen >= 3)
    }

    @Test func goldenRepliesDecodeItemAnswersAndOutcome() throws {
        let replies = try #require(Self.golden()["replies"] as? [[String: Any]])
        #expect(replies.count >= 12)
        for fixture in replies {
            let expect = try #require(fixture["expect"] as? [String: Any])
            let answers = try JSONDecoder().decode([ItemAnswer].self, from: Self.data(expect["item_answers"] ?? []))
            #expect(answers.count == (expect["item_answers"] as? [Any])?.count)
            var reply: [String: Any] = [
                "id": "r1", "case_id": "c1", "idempotency_key": "k", "comments": [], "captures": [], "state": "queued",
                "created_at": "2026-10-08T10:00:00Z", "outcome": expect["outcome"] as Any,
            ]
            reply["item_answers"] = expect["item_answers"]
            reply["intent"] = (fixture["reply"] as? [String: Any])?["intent"]
            let decoded = try JSONDecoder().decode(Reply.self, from: Self.data(reply))
            #expect(decoded.outcome?.rawValue == expect["outcome"] as? String, "\(fixture["name"] ?? "")")
            #expect(decoded.itemAnswers == answers)
        }
    }

    @Test func itemAnswerKeepsTheThreeShapes() throws {
        let list = try JSONDecoder().decode(
            [ItemAnswer].self,
            from: Data(#"[{"item_id":"a","choice":"a2","note":"n"},{"item_id":"b","choices":["b1","b3"]},{"item_id":"c","text":"Ship"}]"#.utf8))
        #expect(list[0] == ItemAnswer(itemId: "a", choice: "a2", note: "n"))
        #expect(list[1].choices == ["b1", "b3"] && list[2].text == "Ship")
        let encoded = try JSONEncoder().encode(list[0])
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["item_id"] as? String == "a" && object["choice"] as? String == "a2" && object["choices"] == nil)
    }

    @Test func anUnknownOutcomeSelectOrExtraFieldNeverBreaksTheCase() throws {
        let raw: [[String: Any]] = [["id": "x", "select": "slider", "options": [["id": "a", "label": "A"]], "future_field": 1]]
        let decoded = try JSONDecoder().decode(Case.self, from: Self.data(Self.caseJSON(items: raw, extra: ["brand_new": ["x": 1]])))
        #expect(decoded.items.count == 1 && decoded.items[0].select == .one)
        let reply = try JSONDecoder().decode(
            Reply.self,
            from: Data(#"{"id":"r","case_id":"c","idempotency_key":"k","comments":[],"captures":[],"state":"queued","created_at":"x","outcome":"sideways"}"#.utf8))
        #expect(reply.outcome == nil)
    }

    @Test func aPayloadWithNoItemsDecodesAsBefore() throws {
        let decoded = try JSONDecoder().decode(Case.self, from: Self.data(Self.caseJSON()))
        #expect(decoded.items.isEmpty)
        let reply = try JSONDecoder().decode(
            Reply.self, from: Data(#"{"id":"r","case_id":"c","idempotency_key":"k","comments":[],"captures":[],"state":"queued","created_at":"x"}"#.utf8))
        #expect(reply.outcome == nil && reply.itemAnswers == nil)
    }

    @Test func caseDetailDecodesRounds() throws {
        let round: [String: Any] = [
            "seq": 1, "stage": ["name": "approaches", "step": 1, "total": 3], "question": "Which approach?",
            "items": [["id": "main", "select": "one", "options": [["id": "a", "label": "A"], ["id": "b", "label": "B"]]]],
            "created_at": "2026-10-08T10:00:00Z", "revision": 2, "own_artifact": true, "artifact_kind": "markdown",
            "answer": ["choice": "a", "item_answers": [["item_id": "main", "choice": "a"]], "created_at": "2026-10-08T11:00:00Z"],
            "talk_count": 1,
        ]
        let detail: [String: Any] = [
            "case": Self.caseJSON(), "task": ["id": "t1", "name": "n", "project": "p"], "messages": [], "revisions": [],
            "comments": [], "replies": [], "rounds": [round],
        ]
        let decoded = try JSONDecoder().decode(CaseDetail.self, from: Self.data(detail))
        let first = try #require(decoded.rounds?.first)
        #expect(first.seq == 1 && first.stage?.name == .approaches && first.items.count == 1 && first.talkCount == 1)
        #expect(first.answer?.itemAnswers == [ItemAnswer(itemId: "main", choice: "a")])
        #expect(first.artifactKind == .markdown && first.ownArtifact)
    }
}
