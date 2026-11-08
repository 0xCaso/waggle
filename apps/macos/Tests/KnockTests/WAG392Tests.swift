import Combine
import Foundation
import Testing
@testable import Knock

/// WAG-392: sign in at the first share, the Account page, Change audience, the guest byline.
struct WAG392Tests {
    private func decode(_ json: String) throws -> SharingState {
        try JSONDecoder().decode(SharingState.self, from: Data(json.utf8))
    }

    private func state(account: AccountState, share: CaseShare? = nil, enabled: Bool = true) -> SharingState {
        SharingState(enabled: enabled, sharedCount: share == nil ? 0 : 1, share: share, comments: [], error: nil, account: account)
    }

    private let code = AccountConnect(userCode: "WXYZ-2345", verifyUrl: "https://app.waggle.so/connect?code=WXYZ-2345", expiresAt: 1)

    // MARK: Decoding

    @Test func theStateReadsTheAccount() throws {
        let s = try decode("""
        {"enabled":true,"shared_count":0,"share":null,"comments":[],"error":null,
         "account":{"signed_in":false,"email":null,
           "connect":{"user_code":"WXYZ-2345","verify_url":"https://app.waggle.so/connect?code=WXYZ-2345","expires_at":1},"error":null}}
        """)
        #expect(!s.account.signedIn)
        #expect(s.account.connect?.userCode == "WXYZ-2345")
    }

    @Test func anOlderDaemonWithoutAnAccountDoesNotBlockSharing() throws {
        let s = try decode(#"{"enabled":true,"shared_count":0,"comments":[],"error":null}"#)
        #expect(s.account.signedIn)
        #expect(!AccountLogic.needsSignIn(s))
    }

    @Test func theStateReadsTheInviteCountsAndSaysSoInOneLine() throws {
        let s = try decode(#"{"enabled":true,"shared_count":1,"comments":[],"error":null,"invites":{"sent":3,"failed":1,"limited":2}}"#)
        #expect(s.invites == InviteCounts(sent: 3, failed: 1, limited: 2))
        #expect(ShareSheetLogic.inviteLine(s.invites) == "3 invites did not go out. They can still sign in with the link.")
        #expect(ShareSheetLogic.inviteLine(InviteCounts(sent: 2, failed: 1, limited: 0)) == "1 invite did not go out. They can still sign in with the link.")
        #expect(ShareSheetLogic.inviteLine(InviteCounts(sent: 5, failed: 0, limited: 0)) == nil)
        // An older daemon sends none: no line.
        #expect(try decode(#"{"enabled":true,"shared_count":0,"comments":[],"error":null}"#).invites == .none)
    }

    @Test func aShareReadsItsFields() throws {
        let r = try JSONDecoder().decode(AccountSharesResult.self, from: Data("""
        {"shares":[{"relay_id":"r1","title":"Pricing","url":"https://app.waggle.so/d/r1","mode":"emails","created_at":1760000000000,
          "comment_count":3,"device_label":"Ada's Mac","local_case_id":null}],"error":null}
        """.utf8))
        #expect(r.shares[0].relayId == "r1")
        #expect(r.shares[0].localCaseId == nil)
        let line = AccountLogic.detail(r.shares[0])
        #expect(line.contains("Only listed emails"))
        #expect(line.contains("3 comments"))
        #expect(line.contains("Ada's Mac"))
        #expect(AccountLogic.commentsLabel(1) == "1 comment")
    }

    // MARK: Sign-in step

    @Test func signInShowsOnlyWithSharingOnNoAccountAndNoShare() {
        #expect(AccountLogic.needsSignIn(state(account: .signedOut)))
        #expect(!AccountLogic.needsSignIn(state(account: AccountState(signedIn: true, email: "a@b.co"))))
        #expect(!AccountLogic.needsSignIn(state(account: .signedOut, enabled: false)))
        #expect(!AccountLogic.needsSignIn(state(account: .signedOut, share: CaseShare(url: "u", mode: .link, emails: []))))
    }

    @Test func theCopyIsPlain() {
        #expect(AccountLogic.signInLine == "Sign in so your team knows the link is from you.")
        #expect(AccountLogic.connectTitle(problem: nil) == "Continue in browser")
        #expect(AccountLogic.connectTitle(problem: "x") == "Try again")
        for text in [AccountLogic.signInLine, AccountLogic.waitingLine, AccountLogic.stopConfirmText] {
            #expect(!text.contains("\u{2014}"))
        }
        #expect(AccountLogic.browserURL("javascript:alert(1)") == nil)
        #expect(AccountLogic.browserURL("https://app.waggle.so/connect") != nil)
    }

    @MainActor @Test func continueInBrowserOpensTheVerifyUrlAndShowsTheCode() async {
        var opened: [URL] = []
        let model = AccountConnectModel(
            get: { .signedOut },
            start: { AccountState(signedIn: false, connect: self.code) },
            cancel: { .signedOut },
            open: { opened.append($0) })
        await model.start()
        #expect(opened.map(\.absoluteString) == ["https://app.waggle.so/connect?code=WXYZ-2345"])
        #expect(model.isWaiting)
        #expect(model.account.connect?.userCode == "WXYZ-2345")
        #expect(model.problem == nil)
    }

    @MainActor @Test func cancelStopsTheWait() async {
        let model = AccountConnectModel(
            initial: AccountState(signedIn: false, connect: code),
            get: { .signedOut }, start: { .signedOut }, cancel: { .signedOut })
        #expect(model.isWaiting)
        await model.cancel()
        #expect(!model.isWaiting)
    }

    @MainActor @Test func aFailedStartShowsTheLineAndTryAgain() async {
        let model = AccountConnectModel(
            get: { .signedOut },
            start: { AccountState(signedIn: false, error: "Sharing is off. Turn it on in Settings.") },
            cancel: { .signedOut }, open: { _ in })
        await model.start()
        #expect(model.problem == "Sharing is off. Turn it on in Settings.")
        #expect(model.buttonTitle == "Try again")
    }

    @MainActor @Test func pollingGoesOnToTheShareStepWhenSignedIn() async {
        var signedIn = false
        let model = SharingModel(
            caseId: "c",
            fetch: {
                SharingState(
                    enabled: true, sharedCount: 0, share: nil, comments: [], error: nil,
                    account: signedIn ? AccountState(signedIn: true, email: "a@b.co") : .signedOut)
            },
            connect: AccountConnectModel(
                initial: AccountState(signedIn: false, connect: code),
                get: { signedIn ? AccountState(signedIn: true, email: "a@b.co") : AccountState(signedIn: false, connect: self.code) },
                start: { .signedOut }, cancel: { .signedOut }))
        await model.load()
        #expect(model.needsSignIn)
        #expect(await model.connect.pollOnce() == false)
        #expect(model.needsSignIn)
        signedIn = true
        #expect(await model.connect.pollOnce())
        #expect(!model.needsSignIn)
    }

    @MainActor @Test func anExpiredCodeSaysSoAndOffersTryAgain() async {
        let model = AccountConnectModel(
            initial: AccountState(signedIn: false, connect: code),
            get: { AccountState(signedIn: false, error: "The sign-in code ran out. Try again.") },
            start: { .signedOut }, cancel: { .signedOut })
        await model.pollOnce()
        #expect(model.problem == "The sign-in code ran out. Try again.")
        #expect(model.buttonTitle == "Try again")
    }

    @MainActor @Test func pollingStopsWhenNoCodeIsShown() async {
        var calls = 0
        let model = AccountConnectModel(get: { calls += 1; return .signedOut }, start: { .signedOut }, cancel: { .signedOut })
        await model.poll(interval: .milliseconds(5))
        #expect(calls == 0)
    }

    // MARK: Account page

    private func share(_ id: String, local: String? = nil) -> AccountShare {
        AccountShare(relayId: id, title: "T\(id)", url: "https://app.waggle.so/d/\(id)", mode: .link, createdAt: 1, commentCount: 0, deviceLabel: "Mac", localCaseId: local)
    }

    @MainActor private func accountModel(
        account: AccountState, shares: [AccountShare], opened: @escaping (URL) -> Void = { _ in }
    ) -> AccountSettingsModel {
        var list = shares
        var current = account
        return AccountSettingsModel(
            connect: AccountConnectModel(get: { current }, start: { .signedOut }, cancel: { .signedOut }),
            get: { current },
            signOut: { current = .signedOut; return current },
            shares: { AccountSharesResult(shares: current.signedIn ? list : [], error: nil) },
            stop: { id in list.removeAll { $0.relayId == id }; return AccountSharesResult(shares: list, error: nil) },
            open: opened, retryInterval: .milliseconds(1))
    }

    @MainActor @Test func signedOutShowsNoLinks() async {
        let model = accountModel(account: .signedOut, shares: [share("a")])
        await model.load()
        #expect(model.loaded)
        #expect(!model.account.signedIn)
        #expect(model.shares.isEmpty)
    }

    @MainActor @Test func signedInListsTheLinksAndStopRemovesOne() async {
        let model = accountModel(account: AccountState(signedIn: true, email: "a@b.co"), shares: [share("a"), share("b")])
        await model.load()
        #expect(model.account.email == "a@b.co")
        #expect(model.shares.map(\.relayId) == ["a", "b"])
        await model.stop(model.shares[0])
        #expect(model.shares.map(\.relayId) == ["b"])
    }

    @MainActor @Test func stopOfALocalShareRefreshesThatCasesSheet() async {
        var stopped = false
        let sheet = SharingModel(caseId: "local1", fetch: {
            SharingState(
                enabled: true, sharedCount: stopped ? 0 : 1,
                share: stopped ? nil : CaseShare(url: "u", mode: .link, emails: []), comments: [], error: nil)
        })
        await sheet.load()
        #expect(sheet.isShared)
        SharingModels.register(sheet)
        let model = AccountSettingsModel(
            connect: AccountConnectModel(get: { .signedOut }, start: { .signedOut }, cancel: { .signedOut }),
            get: { AccountState(signedIn: true, email: "a@b.co") },
            signOut: { .signedOut },
            shares: { AccountSharesResult(shares: [], error: nil) },
            stop: { _ in stopped = true; return AccountSharesResult(shares: [], error: nil) })
        await model.stop(share("r", local: "local1"))
        #expect(!sheet.isShared)
    }

    @MainActor @Test func signOutClearsTheListAndOpenUsesTheLinkOnly() async {
        var opened: [String] = []
        let model = accountModel(account: AccountState(signedIn: true, email: "a@b.co"), shares: [share("a")], opened: { opened.append($0.absoluteString) })
        await model.load()
        model.openShare(model.shares[0])
        #expect(opened == ["https://app.waggle.so/d/a"])
        await model.signOut()
        #expect(!model.account.signedIn)
        #expect(model.shares.isEmpty)
    }

    /// WAG-396: the Account page redraws when the sign-in code shows, so the wait step and its poll run.
    @MainActor @Test func aSignInCodeRedrawsTheAccountPage() async {
        let code = self.code
        let model = AccountSettingsModel(
            connect: AccountConnectModel(get: { .signedOut }, start: { AccountState(signedIn: false, email: nil, connect: code) }, cancel: { .signedOut }, open: { _ in }),
            get: { .signedOut },
            signOut: { .signedOut },
            shares: { AccountSharesResult(shares: [], error: nil) },
            stop: { _ in AccountSharesResult(shares: [], error: nil) })
        var changes = 0
        let watch = model.objectWillChange.sink { _ in changes += 1 }
        await model.connect.start()
        #expect(model.connect.isWaiting)
        #expect(changes > 0)
        watch.cancel()
    }

    @Test func theAccountPageSitsAfterSharing() {
        let pages = SettingsPage.allCases
        #expect(pages.firstIndex(of: .account) == pages.firstIndex(of: .sharing)! + 1)
        #expect(SettingsPage.account.title == "Account")
        #expect(!SettingsPage.account.subtitle.contains("\u{2014}"))
        #expect(SettingsPage.initial(environment: ["KNOCK_SETTINGS_PAGE": "account"]) == .account)
    }

    // MARK: Change audience, Open page

    private let linkShare = CaseShare(url: "https://app.waggle.so/d/x", mode: .link, emails: [])
    private let emailShare = CaseShare(url: "https://app.waggle.so/d/x", mode: .emails, emails: ["ada@example.com", "bo@example.com"])

    @Test func saveNeedsARealChange() {
        #expect(!ShareSheetLogic.canSaveChange(share: linkShare, mode: .link, emailText: "", busy: false))
        #expect(ShareSheetLogic.canSaveChange(share: linkShare, mode: .emails, emailText: "ada@example.com", busy: false))
        #expect(!ShareSheetLogic.canSaveChange(share: linkShare, mode: .emails, emailText: "", busy: false))
        #expect(!ShareSheetLogic.canSaveChange(share: emailShare, mode: .emails, emailText: "bo@example.com, ada@example.com", busy: false))
        #expect(ShareSheetLogic.canSaveChange(share: emailShare, mode: .emails, emailText: "ada@example.com", busy: false))
        #expect(ShareSheetLogic.canSaveChange(share: emailShare, mode: .link, emailText: "", busy: false))
        #expect(!ShareSheetLogic.canSaveChange(share: emailShare, mode: .link, emailText: "", busy: true))
    }

    @Test func changeKeepsTheFiftyEmailCap() {
        let fiftyOne = (1...51).map { "p\($0)@example.com" }.joined(separator: ", ")
        #expect(!ShareSheetLogic.canSaveChange(share: linkShare, mode: .emails, emailText: fiftyOne, busy: false))
        #expect(ShareSheetLogic.tooManyEmails(fiftyOne) == "50 emails at most.")
    }

    @MainActor @Test func changeOpensFilledAndSaveSendsTheNewAudience() async {
        var sent: [(SharingMode, [String]?)] = []
        let model = SharingModel(
            caseId: "c",
            fetch: { SharingState(enabled: true, sharedCount: 1, share: self.emailShare, comments: [], error: nil) },
            update: { mode, emails in
                sent.append((mode, emails))
                return SharingState(enabled: true, sharedCount: 1, share: CaseShare(url: "u", mode: mode, emails: emails ?? []), comments: [], error: nil)
            })
        await model.load()
        model.beginChangeAudience()
        #expect(model.isChangingAudience)
        #expect(model.mode == .emails)
        #expect(model.emailText == "ada@example.com, bo@example.com")
        #expect(!model.canSaveChange)
        model.emailText = "ada@example.com, cy@example.com"
        #expect(model.canSaveChange)
        await model.saveChangeAudience()
        #expect(sent.count == 1)
        #expect(sent[0].0 == .emails)
        #expect(sent[0].1 == ["ada@example.com", "cy@example.com"])
        #expect(!model.isChangingAudience)
    }

    @MainActor @Test func changeToLinkSendsNoEmailsAndCancelLeavesTheShare() async {
        var sent: [(SharingMode, [String]?)] = []
        let model = SharingModel(
            caseId: "c",
            fetch: { SharingState(enabled: true, sharedCount: 1, share: self.emailShare, comments: [], error: nil) },
            update: { mode, emails in sent.append((mode, emails)); return .off })
        await model.load()
        model.beginChangeAudience()
        model.cancelChangeAudience()
        #expect(!model.isChangingAudience)
        #expect(sent.isEmpty)
        model.beginChangeAudience()
        model.mode = .link
        await model.saveChangeAudience()
        #expect(sent.count == 1)
        #expect(sent[0].0 == .link)
        #expect(sent[0].1 == nil)
    }

    @MainActor @Test func aFailedSaveKeepsTheEditOpenWithAPlainLine() async {
        let model = SharingModel(
            caseId: "c",
            fetch: { SharingState(enabled: true, sharedCount: 1, share: self.linkShare, comments: [], error: nil) },
            update: { _, _ in throw JSONRPCErrorPayload(code: -32010, message: "The sharing service said: 50 emails at most.") })
        await model.load()
        model.beginChangeAudience()
        model.mode = .emails
        model.emailText = "ada@example.com"
        await model.saveChangeAudience()
        #expect(model.isChangingAudience)
        #expect(model.problem == "The sharing service said: 50 emails at most.")
    }

    @MainActor @Test func openPageOpensTheReturnedUrl() async {
        var opened: [URL] = []
        let model = SharingModel(
            caseId: "c", fetch: { .off }, openPage: { "https://app.waggle.so/o/once" }, openURL: { opened.append($0) })
        await model.openPage()
        #expect(opened.map(\.absoluteString) == ["https://app.waggle.so/o/once"])
        let bad = SharingModel(caseId: "c", fetch: { .off }, openPage: { "file:///etc/passwd" }, openURL: { opened.append($0) })
        await bad.openPage()
        #expect(opened.count == 1)
        #expect(bad.problem != nil)
    }

    // MARK: Byline

    private func comment(kind: String, name: String = "Ada", email: String? = nil, revision: Int? = nil) -> SharedComment {
        SharedComment(
            id: "1", revision: revision, authorName: name, authorKind: kind, authorEmail: email, body: "x", quote: nil,
            prefix: nil, suffix: nil, box: nil, createdAt: "2026-10-18T10:00:00Z")
    }

    @Test func guestsGetAQuietLabelOthersDoNot() {
        #expect(SharedCommentText.kindLabel(comment(kind: "guest")) == "guest")
        #expect(SharedCommentText.kindLabel(comment(kind: "member", email: "a@b.co")) == nil)
        #expect(SharedCommentText.kindLabel(comment(kind: "owner", email: "me@b.co")) == nil)
    }

    @Test func theBylineKeepsNameAndRoundAndFallsBackToTheEmail() {
        #expect(SharedCommentText.byline(comment(kind: "member", revision: 2)) == "Ada · round 2")
        #expect(SharedCommentText.byline(comment(kind: "owner", name: " ", email: "me@b.co")) == "me@b.co")
    }

    @Test func aCommentReadsItsAuthorEmail() throws {
        let c = try JSONDecoder().decode(SharedComment.self, from: Data("""
        {"id":"1","revision":1,"author_name":"Ada","author_kind":"member","author_email":"ada@example.com","body":"hi",
         "quote":null,"prefix":null,"suffix":null,"box":null,"created_at":"2026-10-18T10:00:00Z"}
        """.utf8))
        #expect(c.authorEmail == "ada@example.com")
        let g = try JSONDecoder().decode(SharedComment.self, from: Data("""
        {"id":"2","author_name":"Guest","author_kind":"guest","body":"hi","created_at":"2026-10-18T10:00:00Z"}
        """.utf8))
        #expect(g.authorEmail == nil)
    }
}
