import Foundation
import Testing
@testable import Knock

/// WAG-391: safe stop, plain errors, the 50 email cap, skipped rounds, comments that stay.
struct WAG391Tests {
    private func decode(_ json: String) throws -> SharingState {
        try JSONDecoder().decode(SharingState.self, from: Data(json.utf8))
    }

    @Test func theEmailListStopsAtFifty() {
        let fifty = (1...50).map { "p\($0)@example.com" }.joined(separator: ", ")
        let fiftyOne = fifty + ", p51@example.com"
        #expect(ShareSheetLogic.tooManyEmails(fifty) == nil)
        #expect(ShareSheetLogic.tooManyEmails(fiftyOne) == "50 emails at most.")
        #expect(ShareSheetLogic.canShare(mode: .emails, emailText: fifty, busy: false))
        #expect(!ShareSheetLogic.canShare(mode: .emails, emailText: fiftyOne, busy: false))
        #expect(ShareSheetLogic.canShare(mode: .link, emailText: fiftyOne, busy: false))
    }

    @Test func theStateReadsStoppableAndSkippedRounds() throws {
        let state = try decode("""
        {"enabled":true,"shared_count":1,
         "share":{"url":"https://app.waggle.so/d/x","mode":"link","emails":[],"stoppable":false},
         "comments":[],"error":null,
         "skipped":[{"revision":2,"reason":"huge.bin in round 2 is over 1 MB."}]}
        """)
        #expect(state.share?.stoppable == false)
        #expect(state.skipped == [SkippedRound(revision: 2, reason: "huge.bin in round 2 is over 1 MB.")])
    }

    @Test func anOlderDaemonAnswerStillReads() throws {
        let state = try decode("""
        {"enabled":true,"shared_count":1,"share":{"url":"u","mode":"link","emails":[]},"comments":[],"error":null}
        """)
        #expect(state.share?.stoppable == true)
        #expect(state.skipped.isEmpty)
    }

    @MainActor @Test func aLinkWithoutItsKeyCannotBeStoppedAndSaysWhy() async {
        let lost = SharingState(
            enabled: true, sharedCount: 1, share: CaseShare(url: "u", mode: .link, emails: [], stoppable: false),
            comments: [], error: nil)
        let model = SharingModel(caseId: "c", fetch: { lost })
        await model.load()
        #expect(!model.canStop)
        #expect(model.errorLine == "This Mac no longer has the key for this link.")
        #expect(!ShareSheetLogic.keyMissingLine.contains("\u{2014}"))
    }

    @MainActor @Test func aNormalSharedCaseCanBeStoppedAndShowsTheRelaysLine() async {
        let ok = SharingState(
            enabled: true, sharedCount: 1, share: CaseShare(url: "u", mode: .link, emails: []), comments: [],
            error: "The sharing service said: 50 emails at most.")
        let model = SharingModel(caseId: "c", fetch: { ok })
        await model.load()
        #expect(model.canStop)
        #expect(model.errorLine == "The sharing service said: 50 emails at most.")
    }

    @MainActor @Test func commentsStayAfterTheShareStops() async {
        let comment = SharedComment(
            id: "k", revision: 1, authorName: "Ada", authorKind: "guest", body: "Ship it", quote: nil, prefix: nil,
            suffix: nil, box: nil, createdAt: "2026-10-17T10:00:00.000Z")
        let stopped = SharingState(enabled: true, sharedCount: 0, share: nil, comments: [comment], error: nil)
        let model = SharingModel(caseId: "c", fetch: { stopped })
        await model.load()
        #expect(!model.isShared)
        #expect(model.comments.map(\.body) == ["Ship it"])
    }
}
