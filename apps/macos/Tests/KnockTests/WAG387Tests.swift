import Foundation
import Testing
@testable import Knock

/// WAG-387: sharing a case. The sheet's logic, the comment list, and the daemon's JSON.
struct WAG387Tests {
    @Test func emailsAreSplitLowercasedAndDeduped() {
        let list = ShareSheetLogic.parseEmails("Ada@Example.com, bo@example.com;\nada@example.com  cy@example.com")
        #expect(list == ["ada@example.com", "bo@example.com", "cy@example.com"])
        #expect(ShareSheetLogic.parseEmails("  ,  ").isEmpty)
    }

    @Test func anEmailNeedsAnAtAndADomain() {
        #expect(ShareSheetLogic.isEmail("ada@example.com"))
        #expect(!ShareSheetLogic.isEmail("ada"))
        #expect(!ShareSheetLogic.isEmail("ada@example"))
        #expect(!ShareSheetLogic.isEmail("@example.com"))
        #expect(!ShareSheetLogic.isEmail("a b@example.com"))
    }

    @Test func theShareButtonOfTheSheetFollowsTheMode() {
        #expect(ShareSheetLogic.canShare(mode: .link, emailText: "", busy: false))
        #expect(!ShareSheetLogic.canShare(mode: .link, emailText: "", busy: true))
        #expect(!ShareSheetLogic.canShare(mode: .emails, emailText: "", busy: false))
        #expect(!ShareSheetLogic.canShare(mode: .emails, emailText: "ada@example.com, nope", busy: false))
        #expect(ShareSheetLogic.canShare(mode: .emails, emailText: "ada@example.com, bo@example.com", busy: false))
    }

    @Test func theAudienceLineSaysWhoCanSee() {
        #expect(ShareSheetLogic.audience(CaseShare(url: "u", mode: .link, emails: [])) == "Anyone with the link can read it and comment.")
        #expect(ShareSheetLogic.audience(CaseShare(url: "u", mode: .emails, emails: ["ada@example.com"])) == "Only ada@example.com can read it and comment.")
        #expect(ShareSheetLogic.audience(CaseShare(url: "u", mode: .emails, emails: ["a@x.com", "b@x.com"])).contains("2 emails"))
        #expect(!ShareSheetLogic.offLine.contains("\u{2014}"))
    }

    private func comment(quote: String? = nil, box: SharedCommentBox? = nil, revision: Int? = 2) -> SharedComment {
        SharedComment(
            id: "k", revision: revision, authorName: "Ada", authorKind: "guest", body: "Why hourly?",
            quote: quote, prefix: nil, suffix: nil, box: box, createdAt: "2026-10-17T10:00:00.000Z")
    }

    @Test func aCommentShowsTheNameTheQuoteOrTheArea() {
        #expect(SharedCommentText.byline(comment()) == "Ada \u{00B7} round 2")
        #expect(SharedCommentText.byline(comment(revision: nil)) == "Ada")
        #expect(SharedCommentText.anchor(comment(quote: "every hour")) == "\u{201C}every hour\u{201D}")
        let box = SharedCommentBox(x: 1, y: 2, w: 3, h: 4, vw: 800, near: "Pricing table")
        #expect(SharedCommentText.anchor(comment(box: box)) == "Area near \u{201C}Pricing table\u{201D}")
        let blank = SharedCommentBox(x: 1, y: 2, w: 3, h: 4, vw: 800, near: "")
        #expect(SharedCommentText.anchor(comment(box: blank)) == "Area on the page")
        #expect(SharedCommentText.anchor(comment()) == nil)
        let long = String(repeating: "word ", count: 80)
        #expect((SharedCommentText.anchor(comment(quote: long)) ?? "").count < 160)
    }

    @Test func theDaemonStateDecodes() throws {
        let json = """
        {"enabled":true,"shared_count":1,"share":{"url":"https://app.waggle.so/d/abc","mode":"emails","emails":["ada@example.com"]},
         "comments":[{"id":"k1","revision":1,"author_name":"Ada","author_kind":"guest","body":"Hi","quote":"q","prefix":null,"suffix":null,
         "box":{"x":1,"y":2,"w":3,"h":4,"vw":800,"near":"Pricing"},"created_at":"2026-10-17T10:00:00.000Z"}],"error":null}
        """
        let state = try JSONDecoder().decode(SharingState.self, from: Data(json.utf8))
        #expect(state.enabled && state.sharedCount == 1)
        #expect(state.share?.mode == .emails)
        #expect(state.comments.first?.box?.near == "Pricing")
        #expect(state.error == nil)
    }

    @Test func sharingHasItsOwnSettingsPage() {
        #expect(SettingsPage.allCases.contains(.sharing))
        #expect(SettingsPage.sharing.title == "Sharing")
    }

    // WAG-389

    @Test func theMainButtonSaysTryAgainAfterAProblem() {
        #expect(ShareSheetLogic.primaryTitle(busy: false, problem: nil) == "Share")
        #expect(ShareSheetLogic.primaryTitle(busy: false, problem: "Could not reach it") == "Try again")
        #expect(ShareSheetLogic.primaryTitle(busy: true, problem: "x") == "Sharing...")
    }

    @Test func theSheetNamesTheFirstBadEmail() {
        #expect(ShareSheetLogic.firstBadEmail("ada@example.com, bo@exmple") == "bo@exmple")
        #expect(ShareSheetLogic.firstBadEmail("ada@example.com") == nil)
        #expect(ShareSheetLogic.firstBadEmail("") == nil)
    }

    @Test func theShareButtonHidesWithSharingOffUnlessTheCaseIsShared() {
        #expect(!ShareSheetLogic.showsButton(enabled: false, isShared: false))
        #expect(ShareSheetLogic.showsButton(enabled: false, isShared: true))
        #expect(ShareSheetLogic.showsButton(enabled: true, isShared: false))
    }

    private let on = SharingState(enabled: true, sharedCount: 0, share: nil, comments: [], error: nil)

    @MainActor @Test func copiedShowsThenGoesBack() async throws {
        let model = SharingModel(caseId: "c", fetch: { .off })
        #expect(!model.copied)
        model.markCopied(hold: .milliseconds(40))
        #expect(model.copied)
        // Wait with a deadline, not a fixed sleep: under a loaded full run the main actor can be late.
        let deadline = ContinuousClock.now + .seconds(10)
        while model.copied && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!model.copied)
    }

    @MainActor @Test func theCaseModelAsksAgainUntilTheDaemonAnswers() async {
        let tries = Counter()
        let state = on
        let model = SharingModel(caseId: "c", fetch: {
            if await tries.next() < 3 { throw URLError(.cannotConnectToHost) }
            return state
        })
        #expect(!model.loaded && !model.showsButton)
        await model.loadUntilReady(tries: 5, delay: .milliseconds(5))
        #expect(model.loaded && model.state.enabled && model.showsButton)
        #expect(await tries.count == 3)
    }

    @MainActor @Test func settingsShowsTheRealStateWhenTheDaemonComesUpLate() async {
        let tries = Counter()
        let state = on
        let model = SharingSettingsModel(fetch: {
            if await tries.next() < 4 { throw URLError(.cannotConnectToHost) }
            return state
        })
        #expect(!model.loaded)
        await model.loadUntilReady()
        #expect(model.loaded && model.state.enabled)
        #expect(await tries.count == 4)
    }
}

private actor Counter {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}
