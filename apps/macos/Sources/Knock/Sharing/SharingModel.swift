import AppKit
import Foundation

/// The pure parts of the Share sheet (WAG-387): who can see the case, the email list, and the words.
enum ShareSheetLogic {
    /// Emails typed with commas, spaces or lines between them: trimmed, lowercase, no repeats.
    static func parseEmails(_ text: String) -> [String] {
        var seen = Set<String>()
        return text
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func isEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !text.contains(where: \.isWhitespace) else { return false }
        let domain = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return domain.count >= 2 && domain.allSatisfy { !$0.isEmpty }
    }

    /// One plain line when invite mails did not go out, else nil. The people can still sign in with the link.
    static func inviteLine(_ invites: InviteCounts) -> String? {
        let n = invites.failed + invites.limited
        if n <= 0 { return nil }
        return "\(n) \(n == 1 ? "invite" : "invites") did not go out. They can still sign in with the link."
    }

    /// The relay takes this many emails at most.
    static let maxEmails = 50

    /// A plain line when the list is over the limit, else nil.
    static func tooManyEmails(_ text: String) -> String? {
        parseEmails(text).count > maxEmails ? "\(maxEmails) emails at most." : nil
    }

    /// Whether the Share button of the sheet can be pressed.
    static func canShare(mode: SharingMode, emailText: String, busy: Bool) -> Bool {
        if busy { return false }
        if mode == .link { return true }
        let emails = parseEmails(emailText)
        return !emails.isEmpty && emails.count <= maxEmails && emails.allSatisfy(isEmail)
    }

    /// The line for a link that this Mac cannot stop (the key is gone).
    static let keyMissingLine = "This Mac no longer has the key for this link."

    /// One plain line that says who can see a shared case.
    static func audience(_ share: CaseShare) -> String {
        switch share.mode {
        case .link: "Anyone with the link can read it and comment."
        case .emails:
            share.emails.count == 1 ? "Only \(share.emails[0]) can read it and comment." : "Only the \(share.emails.count) emails you listed can read it and comment."
        }
    }

    /// WAG-399, row 1 of the shared sheet: "Anyone with the link" or "Only listed emails \u{00B7} 3 people".
    static func audienceSubtitle(_ share: CaseShare) -> String {
        switch share.mode {
        case .link: "Anyone with the link"
        case .emails: "Only listed emails \u{00B7} \(share.emails.count) \(share.emails.count == 1 ? "person" : "people")"
        }
    }

    /// WAG-399, row 2: what the Comments toggle says now.
    static func commentsSubtitle(closed: Bool) -> String {
        closed ? "Closed. Nobody can add a comment." : "Open. People with the link can comment."
    }

    /// WAG-399, row 3 title. The count is the team's comments, as in the Decision tab line.
    static func commentCountTitle(_ comments: [SharedComment]) -> String {
        let n = comments.filter(MergedComments.isTeam).count
        return n == 0 ? "No comments yet" : "\(n) \(n == 1 ? "comment" : "comments")"
    }

    /// WAG-399, row 3 subtitle: "Last one 2h ago", or nil when the team wrote nothing.
    static func lastCommentLine(_ comments: [SharedComment], now: Date = Date()) -> String? {
        let dates = comments.filter(MergedComments.isTeam).compactMap { KnockDateFormat.date(from: $0.createdAt) }
        guard let last = dates.max() else { return nil }
        return "Last one \(CaseTimes.agoLabel(since: last, now: now))"
    }

    /// WAG-399: "View" closes the sheet and opens the case on this tab.
    static let viewTab: ReviewColumnTab = .comments

    /// What "Change" starts from: the emails of a share as one typed line.
    static func emailLine(_ share: CaseShare) -> String { share.emails.joined(separator: ", ") }

    /// Save in the Change view needs a valid new audience that differs from the saved one.
    static func canSaveChange(share: CaseShare, mode: SharingMode, emailText: String, busy: Bool) -> Bool {
        guard canShare(mode: mode, emailText: emailText, busy: busy) else { return false }
        if mode != share.mode { return true }
        return mode == .emails && Set(parseEmails(emailText)) != Set(share.emails)
    }

    /// The first typed email that is not a full address, for the line under the field. Nil when all pass.
    static func firstBadEmail(_ text: String) -> String? {
        parseEmails(text).first { !isEmail($0) }
    }

    /// The title of the sheet's main button: it says "Try again" after a failure.
    static func primaryTitle(busy: Bool, problem: String?) -> String {
        busy ? "Sharing..." : (problem != nil ? "Try again" : "Share")
    }

    /// The Share button shows when Sharing is on, or when the case is already shared (so the person can reach the link).
    static func showsButton(enabled: Bool, isShared: Bool) -> Bool { enabled || isShared }

    static let whatIsShared = "Shares the question, the options and each round's page. Your conversation with the agent stays on this Mac."

    static let offLine = "Sharing is off. Turn it on in Settings, on the Sharing page."
}

/// One shared case as the app sees it: the saved state, the sheet and the comment list read it. One
/// model per case id, so the header button and the comments in the case stay in step.
@MainActor
final class SharingModel: ObservableObject {
    @Published private(set) var state: SharingState = .off
    @Published private(set) var isBusy = false
    /// A plain line for the sheet when the relay is down or says no. The case still works.
    @Published var problem: String?
    @Published var mode: SharingMode = .link
    @Published var emailText = ""
    /// True for a short while after "Copy link", so the button can say "Copied".
    @Published private(set) var copied = false
    /// True once the daemon answered at least once. Until then `state` is the placeholder, not the truth.
    @Published private(set) var loaded = false

    let caseId: String
    private let client: KnockClient?
    private let fetch: () async throws -> SharingState
    private let refreshCall: () async throws -> SharingState
    private let updateCall: (SharingMode, [String]?) async throws -> SharingState
    private let openPageCall: () async throws -> String
    private let replyCall: (String, String) async throws -> SharingState
    private let resolveCall: (String, Bool) async throws -> SharingState
    private let commentCall: (String) async throws -> SharingState
    private let closeCommentsCall: (Bool) async throws -> SharingState
    private let markLateGivenCall: () async throws -> SharingState
    private let openURL: (URL) -> Void
    /// The browser sign-in for the first share.
    let connect: AccountConnectModel
    /// True while the audience line is open for editing in the shared state.
    @Published private(set) var isChangingAudience = false
    private var copyReset: Task<Void, Never>?

    init(caseId: String, client: KnockClient) {
        self.caseId = caseId
        self.client = client
        fetch = { try await client.sharingGet(caseId: caseId) }
        refreshCall = { try await client.sharingRefresh(caseId: caseId) }
        updateCall = { mode, emails in try await client.sharingUpdate(caseId: caseId, mode: mode, emails: emails) }
        openPageCall = { try await client.sharingOpenPage(caseId: caseId) }
        replyCall = { parent, body in try await client.sharingReply(caseId: caseId, parentId: parent, body: body) }
        resolveCall = { id, resolved in try await client.sharingResolve(caseId: caseId, commentId: id, resolved: resolved) }
        commentCall = { body in try await client.sharingComment(caseId: caseId, body: body) }
        closeCommentsCall = { closed in try await client.sharingCloseComments(caseId: caseId, closed: closed) }
        markLateGivenCall = { try await client.sharingMarkLateGiven(caseId: caseId) }
        openURL = { NSWorkspace.shared.open($0) }
        connect = AccountConnectModel(client: client)
        connect.onSignedIn = { [weak self] in await self?.load() }
    }

    /// For tests: the two daemon reads come from closures.
    init(
        caseId: String, fetch: @escaping () async throws -> SharingState, refresh: @escaping () async throws -> SharingState = { .off },
        update: @escaping (SharingMode, [String]?) async throws -> SharingState = { _, _ in .off },
        openPage: @escaping () async throws -> String = { "" },
        openURL: @escaping (URL) -> Void = { _ in },
        connect: AccountConnectModel? = nil,
        reply: @escaping (String, String) async throws -> SharingState = { _, _ in .off },
        resolve: @escaping (String, Bool) async throws -> SharingState = { _, _ in .off },
        closeComments: @escaping (Bool) async throws -> SharingState = { _ in .off },
        comment: @escaping (String) async throws -> SharingState = { _ in .off },
        markLateGiven: @escaping () async throws -> SharingState = { .off }
    ) {
        markLateGivenCall = markLateGiven
        commentCall = comment
        replyCall = reply
        resolveCall = resolve
        closeCommentsCall = closeComments
        self.caseId = caseId
        self.client = nil
        self.fetch = fetch
        refreshCall = refresh
        updateCall = update
        openPageCall = openPage
        self.openURL = openURL
        self.connect = connect ?? AccountConnectModel(get: { .signedOut }, start: { .signedOut }, cancel: { .signedOut })
        self.connect.onSignedIn = { [weak self] in await self?.load() }
    }

    var isShared: Bool { state.share != nil }
    var comments: [SharedComment] { state.comments }
    var threads: [CommentThread] { CommentThreads.build(state.comments) }
    var commentsClosed: Bool { state.commentsClosed }
    /// The words under the audience choice when a case that was shared before is shared again.
    var newLinkNote: String? { TeamCommentCopy.newLinkNote(shared: isShared, sharedBefore: state.sharedBefore) }
    var canShare: Bool { state.enabled && ShareSheetLogic.canShare(mode: mode, emailText: emailText, busy: isBusy) }
    /// The line under the sheet: what the model knows went wrong, else the relay's last problem.
    var errorLine: String? {
        if let problem { return problem }
        guard let share = state.share else { return nil }
        return share.stoppable ? state.error : ShareSheetLogic.keyMissingLine
    }
    /// Stop sharing needs the key. Without it the button stays off and the sheet says why.
    var canStop: Bool { state.share?.stoppable ?? false }
    /// Rounds that were left out of the share, each with its reason.
    var skippedRounds: [SkippedRound] { state.skipped }
    /// Says so when invite mails did not go out after the last share or change.
    var inviteLine: String? { ShareSheetLogic.inviteLine(state.invites) }

    /// The saved state, no network call.
    @discardableResult
    func load() async -> Bool {
        guard let s = try? await fetch() else { return false }
        state = s
        connect.apply(s.account)
        loaded = true
        return true
    }

    /// The sheet shows the sign-in step before the share step.
    var needsSignIn: Bool { AccountLogic.needsSignIn(state) }

    /// The daemon may not be up when the app opens (it starts on demand): ask again until it answers.
    func loadUntilReady(tries: Int = 8, delay: Duration = .seconds(1)) async {
        for attempt in 0..<tries {
            if await load() || Task.isCancelled { return }
            if attempt < tries - 1 { try? await Task.sleep(for: delay) }
        }
    }

    var showsButton: Bool { ShareSheetLogic.showsButton(enabled: state.enabled, isShared: isShared) }

    /// Opening a shared case: upload what is missing, fetch new comments. Quiet when it fails.
    func refresh() async {
        await load()
        guard state.enabled, isShared else { return }
        if let s = try? await refreshCall() { state = s }
    }

    func share() async {
        guard canShare else { return }
        guard let client else { return }
        await run { [self] in try await client.sharingStart(caseId: caseId, mode: mode, emails: ShareSheetLogic.parseEmails(emailText)) }
    }

    func stopSharing() async {
        guard let client else { return }
        await run { [self] in try await client.sharingStop(caseId: caseId) }
    }

    /// Opens the audience choice in place, filled with what is shared now.
    func beginChangeAudience() {
        guard let share = state.share else { return }
        mode = share.mode
        emailText = ShareSheetLogic.emailLine(share)
        problem = nil
        isChangingAudience = true
    }

    func cancelChangeAudience() {
        isChangingAudience = false
        problem = nil
    }

    var canSaveChange: Bool {
        guard let share = state.share else { return false }
        return ShareSheetLogic.canSaveChange(share: share, mode: mode, emailText: emailText, busy: isBusy)
    }

    func saveChangeAudience() async {
        guard canSaveChange else { return }
        let emails: [String]? = mode == .emails ? ShareSheetLogic.parseEmails(emailText) : nil
        await run { [self] in try await updateCall(mode, emails) }
        if problem == nil { isChangingAudience = false }
    }

    /// "Open page": the daemon asks the relay for a one-time link, the browser opens it.
    func openPage() async {
        guard !isBusy else { return }
        isBusy = true
        problem = nil
        defer { isBusy = false }
        do {
            let text = try await openPageCall()
            if let url = AccountLogic.browserURL(text) { openURL(url) } else { problem = "Waggle could not open the page. Try again." }
        } catch {
            problem = PhoneSettingsModel.words(for: error)
        }
    }

    func copyLink() {
        guard let url = state.share?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        markCopied()
    }

    /// Shows "Copied" for `hold`, then goes back. A second copy restarts the time.
    func markCopied(hold: Duration = .milliseconds(1500)) {
        copyReset?.cancel()
        copied = true
        copyReset = Task { [weak self] in
            try? await Task.sleep(for: hold)
            if !Task.isCancelled { self?.copied = false }
        }
    }

    /// A reply under a root comment. The reply field of the thread clears only when it worked, so the
    /// caller reads the result. A failure leaves one plain line in `replyProblems` for that thread.
    @Published private(set) var replyProblems: [String: String] = [:]
    @Published private(set) var replying: Set<String> = []

    @discardableResult
    func reply(to rootId: String, body: String) async -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CommentThreads.canSend(text, busy: replying.contains(rootId), commentsClosed: commentsClosed) else {
            if commentsClosed { replyProblems[rootId] = TeamCommentCopy.closedLine }
            return false
        }
        replying.insert(rootId)
        replyProblems[rootId] = nil
        defer { replying.remove(rootId) }
        do {
            state = try await replyCall(rootId, text)
            return true
        } catch {
            replyProblems[rootId] = Self.replyWords(error)
            return false
        }
    }

    /// "Comments are closed." when the daemon says so, else the usual plain words.
    static func replyWords(_ error: Error) -> String {
        let text = PhoneSettingsModel.words(for: error)
        return text.lowercased().contains("closed") ? TeamCommentCopy.closedLine : text
    }

    /// WAG-397: the line under the page composer when a post failed.
    @Published private(set) var pageProblem: String?
    @Published private(set) var posting = false

    /// A new comment on the page, as the owner. The composer clears only when it worked, so the caller reads
    /// the result. A note to the agent never comes here.
    @discardableResult
    func commentOnPage(_ body: String) async -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CommentThreads.canSend(text, busy: posting, commentsClosed: commentsClosed) else {
            if commentsClosed { pageProblem = TeamCommentCopy.closedLine }
            return false
        }
        posting = true
        pageProblem = nil
        defer { posting = false }
        do {
            state = try await commentCall(text)
            return true
        } catch {
            pageProblem = Self.replyWords(error)
            return false
        }
    }

    /// The switch "On the page" shows only while the case is shared and Sharing is on.
    var canWriteOnPage: Bool { isShared && state.enabled }

    func resolve(_ rootId: String, resolved: Bool) async {
        replyProblems[rootId] = nil
        do { state = try await resolveCall(rootId, resolved) } catch { replyProblems[rootId] = PhoneSettingsModel.words(for: error) }
    }

    /// The late comments (after the decision) of this case, WAG-401.
    var lateComments: LateComments { state.lateComments }

    /// The late comments went to the agent: the daemon marks them given, the bar says "Sent to the agent".
    func markLateGiven() async {
        if let s = try? await markLateGivenCall() { state = s }
    }

    func setCommentsClosed(_ closed: Bool) async {
        await run { [self] in try await closeCommentsCall(closed) }
    }

    /// The sheet closed: the red line goes with it.
    func clearProblem() { problem = nil }

    private func run(_ step: () async throws -> SharingState) async {
        isBusy = true
        problem = nil
        defer { isBusy = false }
        do {
            state = try await step()
        } catch {
            problem = PhoneSettingsModel.words(for: error)
        }
    }
}

/// One `SharingModel` per case id, so every view of the case reads the same one.
@MainActor
enum SharingModels {
    private static var models: [String: SharingModel] = [:]

    /// Read the saved state again for a case that has a model (a link was stopped from the Account page).
    static func reload(caseId: String) async {
        await models[caseId]?.load()
    }

    /// True when the case has a model and it is shared (WAG-401: only a shared page needs reopening).
    static func isShared(caseId: String) -> Bool { models[caseId]?.isShared ?? false }

    /// For tests: use a model that is already built.
    static func register(_ model: SharingModel) { models[model.caseId] = model }

    static func model(for caseId: String, client: KnockClient) -> SharingModel {
        if let found = models[caseId] { return found }
        let made = SharingModel(caseId: caseId, client: client)
        models[caseId] = made
        return made
    }
}

/// How a team comment reads in the case (WAG-387). Plain text only.
enum SharedCommentText {
    /// "Ada · round 2" for the line above the comment.
    static func name(_ c: SharedComment) -> String {
        let trimmed = c.authorName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? (c.authorEmail ?? "Someone") : trimmed
    }

    /// The first line of a comment as plain text: the markers are stripped, the rest is cut.
    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return AgentMarkdown.singleLine(line.trimmingCharacters(in: .whitespaces))
    }

    /// "guest" for a person who is not signed in. Owner and members show as their name.
    static func kindLabel(_ c: SharedComment) -> String? { c.authorKind == "guest" ? "guest" : nil }

    static func byline(_ c: SharedComment) -> String {
        c.revision.map { "\(name(c)) · round \($0)" } ?? name(c)
    }

    /// The quoted text, or "Area near …" for a box, or nil when the comment points at nothing.
    static func anchor(_ c: SharedComment) -> String? {
        if let quote = c.quote, !quote.isEmpty { return "\u{201C}\(clip(quote))\u{201D}" }
        if let box = c.box { return box.near.isEmpty ? "Area on the page" : "Area near \u{201C}\(clip(box.near))\u{201D}" }
        return nil
    }

    private static func clip(_ text: String, max: Int = 140) -> String {
        let one = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return one.count > max ? String(one.prefix(max)).trimmingCharacters(in: .whitespaces) + "..." : one
    }
}
