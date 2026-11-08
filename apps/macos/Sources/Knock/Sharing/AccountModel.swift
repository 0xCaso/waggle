import AppKit
import Combine
import Foundation

/// Words and small decisions for the Waggle account (WAG-392). Local use needs no account; sharing does.
enum AccountLogic {
    static let signInLine = "Sign in so your team knows the link is from you."
    static let waitingLine = "Finish signing in in your browser. This page updates by itself."
    static let stopConfirmTitle = "Stop sharing this case?"
    static let stopConfirmText = "The link stops working for everyone. Their comments stay here."

    /// The sheet shows the sign-in step: Sharing is on, the case is not shared yet and there is no account.
    static func needsSignIn(_ state: SharingState) -> Bool {
        state.enabled && state.share == nil && !state.account.signedIn
    }

    /// The title of the browser button: "Try again" after a failure.
    static func connectTitle(problem: String?) -> String { problem != nil ? "Try again" : "Continue in browser" }

    /// Only a web address opens in the browser.
    static func browserURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    /// "Link" or "Emails" for a row of "Your shared links".
    static func modeLabel(_ mode: SharingMode) -> String { mode == .link ? "Anyone with the link" : "Only listed emails" }

    static func commentsLabel(_ count: Int) -> String { count == 1 ? "1 comment" : "\(count) comments" }

    /// One quiet line under the title of a shared link.
    static func detail(_ share: AccountShare, now: Date = Date()) -> String {
        let when = Date(timeIntervalSince1970: share.createdAt / 1000).formatted(date: .abbreviated, time: .omitted)
        var parts = [modeLabel(share.mode), when, commentsLabel(share.commentCount)]
        if !share.deviceLabel.isEmpty { parts.append(share.deviceLabel) }
        return parts.joined(separator: " · ")
    }
}

/// The browser sign-in: start it, show the code, poll `account.get` every 2 s, cancel it. One model for the
/// Share sheet and the Account page.
@MainActor
final class AccountConnectModel: ObservableObject {
    @Published private(set) var account: AccountState
    @Published private(set) var isBusy = false
    /// A plain line for a failure. "Try again" shows while it is set.
    @Published var problem: String?

    private let getCall: () async throws -> AccountState
    private let startCall: () async throws -> AccountState
    private let cancelCall: () async throws -> AccountState
    private let open: (URL) -> Void
    /// Called once when the sign-in finishes, so the screen can go on.
    var onSignedIn: (() async -> Void)?

    init(
        initial: AccountState = .signedOut,
        get: @escaping () async throws -> AccountState,
        start: @escaping () async throws -> AccountState,
        cancel: @escaping () async throws -> AccountState,
        open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        account = initial
        getCall = get
        startCall = start
        cancelCall = cancel
        self.open = open
    }

    convenience init(client: KnockClient, initial: AccountState = .signedOut) {
        self.init(
            initial: initial,
            get: { try await client.accountGet() },
            start: { try await client.accountConnectStart() },
            cancel: { try await client.accountConnectCancel() })
    }

    var isWaiting: Bool { account.connect != nil }
    var buttonTitle: String { AccountLogic.connectTitle(problem: problem) }

    /// Take a state the daemon already sent (the sharing state carries one). Keeps a code on screen.
    func apply(_ state: AccountState) {
        account = state
        if state.signedIn { problem = nil }
    }

    func start() async {
        guard !isBusy else { return }
        isBusy = true
        problem = nil
        defer { isBusy = false }
        do {
            let state = try await startCall()
            account = state
            if let connect = state.connect, let url = AccountLogic.browserURL(connect.verifyUrl) { open(url) }
            if state.connect == nil { problem = state.error ?? (state.signedIn ? nil : "Waggle could not start the sign-in. Try again.") }
        } catch {
            problem = PhoneSettingsModel.words(for: error)
        }
        if account.signedIn { await onSignedIn?() }
    }

    func cancel() async {
        problem = nil
        if let state = try? await cancelCall() { account = state } else { account = AccountState(signedIn: account.signedIn, email: account.email) }
    }

    /// One `account.get`. True when the sign-in just finished.
    @discardableResult
    func pollOnce() async -> Bool {
        guard let state = try? await getCall() else { return false }
        let wasSignedIn = account.signedIn
        let hadCode = account.connect != nil
        account = state
        if state.signedIn && !wasSignedIn {
            problem = nil
            await onSignedIn?()
            return true
        }
        if hadCode && state.connect == nil && !state.signedIn { problem = state.error ?? "The sign-in code ran out. Try again." }
        return false
    }

    /// Ask again every 2 s while a code is on screen. Stops when it is done or the task is cancelled.
    func poll(interval: Duration = .seconds(2)) async {
        while !Task.isCancelled && account.connect != nil {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return }
            await pollOnce()
        }
    }
}

extension Notification.Name {
    /// The sharing state changed outside the Sharing page (a link was stopped from the Account page).
    static let knockSharingChanged = Notification.Name("knockSharingChanged")
}

/// The Account page: the email, Sign out and "Your shared links".
@MainActor
final class AccountSettingsModel: ObservableObject {
    @Published private(set) var account: AccountState = .signedOut
    @Published private(set) var shares: [AccountShare] = []
    @Published var problem: String?
    @Published private(set) var loaded = false
    @Published private(set) var isBusy = false
    /// The relay id whose Stop sharing is being confirmed.
    @Published var confirmingStop: AccountShare?
    @Published private(set) var stoppingId: String?

    let connect: AccountConnectModel
    private let getCall: () async throws -> AccountState
    private let signOutCall: () async throws -> AccountState
    private let sharesCall: () async throws -> AccountSharesResult
    private let stopCall: (String) async throws -> AccountSharesResult
    private let open: (URL) -> Void
    private let retryInterval: Duration
    /// The page reads `connect` (the code, the wait state), so a change there redraws the page too. Without this
    /// the code never showed, the poll never ran, and the page kept "Sign in" after the browser step.
    private var connectChanges: AnyCancellable?

    init(
        connect: AccountConnectModel,
        get: @escaping () async throws -> AccountState,
        signOut: @escaping () async throws -> AccountState,
        shares: @escaping () async throws -> AccountSharesResult,
        stop: @escaping (String) async throws -> AccountSharesResult,
        open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        retryInterval: Duration = .seconds(1)
    ) {
        self.connect = connect
        getCall = get
        signOutCall = signOut
        sharesCall = shares
        stopCall = stop
        self.open = open
        self.retryInterval = retryInterval
        connect.onSignedIn = { [weak self] in await self?.load() }
        connectChanges = connect.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    convenience init(client: KnockClient) {
        self.init(
            connect: AccountConnectModel(client: client),
            get: { try await client.accountGet() },
            signOut: { try await client.accountSignOut() },
            shares: { try await client.accountShares() },
            stop: { try await client.accountStopShare(relayId: $0) })
    }

    @discardableResult
    func load() async -> Bool {
        guard let state = try? await getCall() else { return false }
        account = state
        connect.apply(state)
        loaded = true
        if state.signedIn {
            if let r = try? await sharesCall() { apply(r) }
        } else {
            shares = []
        }
        return true
    }

    func loadUntilReady() async {
        while !Task.isCancelled {
            if await load() { return }
            try? await Task.sleep(for: retryInterval)
        }
    }

    func signOut() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        problem = nil
        do {
            let state = try await signOutCall()
            account = state
            connect.apply(state)
            if state.signedIn { problem = state.error ?? "Waggle could not sign you out. Try again." } else { shares = [] }
        } catch {
            problem = PhoneSettingsModel.words(for: error)
        }
        NotificationCenter.default.post(name: .knockSharingChanged, object: nil)
    }

    func openShare(_ share: AccountShare) {
        if let url = AccountLogic.browserURL(share.url) { open(url) }
    }

    func stop(_ share: AccountShare) async {
        guard stoppingId == nil else { return }
        stoppingId = share.relayId
        defer { stoppingId = nil }
        problem = nil
        do {
            apply(try await stopCall(share.relayId))
        } catch {
            problem = PhoneSettingsModel.words(for: error)
        }
        // This Mac's own row may be gone: the case sheet and the Sharing switch read the new state.
        if let caseId = share.localCaseId { await SharingModels.reload(caseId: caseId) }
        NotificationCenter.default.post(name: .knockSharingChanged, object: nil)
    }

    private func apply(_ result: AccountSharesResult) {
        shares = result.shares
        if let error = result.error { problem = error }
    }
}
