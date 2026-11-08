import Foundation
import Testing
@testable import Knock

/// WAG-260: the project page words and the RPC shapes.
struct ProjectPageTests {
    private let now = KnockDateFormat.date(from: "2026-10-07T12:00:00Z")!
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test func statsLine() {
        let last = now.addingTimeInterval(-12 * 60)
        #expect(ProjectPageLogic.statsLine(decisions: 31, comments: 46, lastDecisionAt: last, now: now)
            == "31 decisions · 46 comments · last decision 12 min ago")
        #expect(ProjectPageLogic.statsLine(decisions: 1, comments: 1, lastDecisionAt: nil, now: now) == "1 decision · 1 comment")
    }

    @Test func dateLabel() {
        let today = KnockDateFormat.date(from: "2026-10-07T11:02:00Z")!
        let yesterday = KnockDateFormat.date(from: "2026-10-06T08:00:00Z")!
        #expect(ProjectPageLogic.dateLabel(today, now: now, calendar: utc) == "Today 11:02")
        #expect(ProjectPageLogic.dateLabel(yesterday, now: now, calendar: utc) == "Yesterday")
    }

    @Test func tagAndEvidence() {
        #expect(ProjectPageLogic.tag(optionCount: 3, artifactKind: "html_bundle") == "3 options · prototype")
        #expect(ProjectPageLogic.tag(optionCount: 2, artifactKind: nil) == "2 options")
        #expect(ProjectPageLogic.evidenceLine(count: 9, quote: "not a name") == "9 comments · \"not a name\"")
        #expect(ProjectPageLogic.evidenceLine(count: 1, quote: nil) == "1 comment")
        #expect(ProjectPageLogic.themesLabel(comments: 46) == "YOUR THEMES · FROM 46 COMMENTS")
    }

    @Test func decodesProjectInfo() throws {
        let json = """
        {"project":"waggle","decisions":2,"comments":5,"last_decision_at":"2026-10-07T10:00:00.000Z","repo_records":true,
         "themes":[{"id":"th_1","text":"Plain words","evidence_count":3,"quotes":["q"],"enabled":false,"proposed_by":null,
         "created_at":"x","updated_at":"y"}]}
        """
        let info = try JSONDecoder().decode(ProjectInfo.self, from: Data(json.utf8))
        #expect(info.repoRecords)
        #expect(info.themes.first?.enabled == false)
        #expect(info.themes.first?.evidenceCount == 3)
    }

    @Test func decodesDecisions() throws {
        let json = """
        {"items":[{"case_id":"c1","question":"Q?","decided_at":"2026-10-07T10:00:00.000Z","pick":"A","why":"W",
        "option_count":2,"artifact_kind":null}],"total":1}
        """
        let result = try JSONDecoder().decode(ProjectDecisionsResult.self, from: Data(json.utf8))
        #expect(result.items.first?.id == "c1")
        #expect(result.total == 1)
    }
}
