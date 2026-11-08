import Foundation
import Testing
@testable import Knock

/// WAG-399: the shared state of the Share sheet, design A. The text of the three rows and the View target.
@MainActor
struct WAG399Tests {
    private func comment(_ id: String, kind: String = "member", at: String) -> SharedComment {
        SharedComment(
            id: id, revision: 1, authorName: "Ada", authorKind: kind, body: "Hi", quote: nil, prefix: nil, suffix: nil,
            box: nil, createdAt: at)
    }

    @Test func theAudienceSubtitleNamesTheModeAndThePeople() {
        #expect(ShareSheetLogic.audienceSubtitle(CaseShare(url: "u", mode: .link, emails: [])) == "Anyone with the link")
        let two = CaseShare(url: "u", mode: .emails, emails: ["a@x.io", "b@x.io"])
        #expect(ShareSheetLogic.audienceSubtitle(two) == "Only listed emails \u{00B7} 2 people")
        let one = CaseShare(url: "u", mode: .emails, emails: ["a@x.io"])
        #expect(ShareSheetLogic.audienceSubtitle(one) == "Only listed emails \u{00B7} 1 person")
    }

    @Test func theCommentsSubtitleSaysOpenOrClosed() {
        #expect(ShareSheetLogic.commentsSubtitle(closed: false) == "Open. People with the link can comment.")
        #expect(ShareSheetLogic.commentsSubtitle(closed: true) == "Closed. Nobody can add a comment.")
    }

    @Test func theCountAndLastLineCountTheTeamOnly() {
        #expect(ShareSheetLogic.commentCountTitle([]) == "No comments yet")
        #expect(ShareSheetLogic.lastCommentLine([]) == nil)
        let now = ISO8601DateFormatter().date(from: "2026-10-18T12:00:00Z")!
        let list = [
            comment("a", at: "2026-10-18T08:00:00.000Z"),
            comment("b", kind: "guest", at: "2026-10-18T10:00:00.000Z"),
            comment("c", kind: "agent", at: "2026-10-18T11:59:30.000Z"),
        ]
        #expect(ShareSheetLogic.commentCountTitle(list) == "2 comments")
        #expect(ShareSheetLogic.commentCountTitle([list[0]]) == "1 comment")
        #expect(ShareSheetLogic.lastCommentLine(list, now: now) == "Last one 2h ago")
    }

    @Test func viewOpensTheCommentsTab() {
        #expect(ShareSheetLogic.viewTab == .comments)
    }

    @Test func theCopyHasNoEmDashes() {
        let lines = [ShareSheetLogic.commentsSubtitle(closed: true), ShareSheetLogic.commentsSubtitle(closed: false)]
        #expect(lines.allSatisfy { !$0.contains("\u{2014}") })
    }
}
