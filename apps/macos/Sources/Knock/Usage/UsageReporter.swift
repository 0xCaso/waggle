import Foundation

/// The one place the app reports what people click (HAIL-83). Every call site
/// goes through `record`, so a test swaps `sink` for a recording fake and
/// reads back exactly what would have gone over `usage.record`.
///
/// Private by construction: a record holds only closed enums (`UsageRecord`),
/// never a title, text or path. The reporter keeps case ids in memory to
/// time the "after" bucket and to record some events once per ask. The one id
/// it sends is the ask of an ask event (WAG-366), which the daemon stores as a
/// salted hash only.
///
/// A failed report is dropped: an old daemon rejects a new event, and no user
/// action ever waits on this.
@MainActor
final class UsageReporter {
    typealias Sink = @MainActor (UsageRecord) -> Void

    /// The app's reporter (WAG-366), set where the real `AppModel` is made. Models with no `AppModel`
    /// (onboarding, updates, settings) report through it; nil in a test, so nothing is sent.
    static var current: UsageReporter?

    private let sink: Sink
    /// Adds the open ask's id to the events about one ask (WAG-366), so the report can count per ask.
    /// On for the reporter that sends to the daemon.
    var attachesAsk = false
    /// The ask a person opened last.
    private var currentAsk: String?
    /// The UTC hour `app_active` was last recorded in.
    private var activeHour: Int?
    private let clock: () -> Date
    /// When each ask was opened (most recent open).
    private var openedAt: [String: Date] = [:]
    /// "case id + event" pairs already recorded for the current opening.
    private var recorded: Set<String> = []

    init(clock: @escaping () -> Date = Date.init, sink: @escaping Sink) {
        self.clock = clock
        self.sink = sink
    }

    /// A reporter that sends over the daemon socket, best-effort.
    convenience init(client: KnockClient, clock: @escaping () -> Date = Date.init) {
        self.init(clock: clock) { record in
            Task { try? await client.usageRecord(record) }
        }
        attachesAsk = true
    }

    /// One record for one action.
    func record(_ record: UsageRecord) {
        var record = record
        if attachesAsk, record.event.isAskBound, record.caseId == nil { record.caseId = currentAsk }
        sink(record)
    }

    func record(_ event: UsageEvent, source: String? = nil, variant: UsageVariant? = nil) {
        record(UsageRecord(event, source: source, variant: variant))
    }

    /// An event whose variant is the raw value of another closed enum (WAG-366).
    func record(_ event: UsageEvent, variantName: String, n: Int? = nil) {
        record(UsageRecord(event, variantName: variantName, n: n))
    }

    /// The app came to the front: one `app_active` per UTC hour at most, so the report can count
    /// the hours and days Waggle was in use.
    func appBecameActive() {
        let hour = Int(clock().timeIntervalSince1970 / 3600)
        guard activeHour != hour else { return }
        activeHour = hour
        record(.appActive)
    }

    /// The ask was opened by a person: starts its clock and forgets what was
    /// recorded once for the previous opening.
    func askOpened(caseId: String) {
        openedAt[caseId] = clock()
        currentAsk = caseId
        recorded = recorded.filter { !$0.hasPrefix("\(caseId)|") }
    }

    /// Records `event` for `caseId` the first time only, until the ask is
    /// opened again. Returns whether it was recorded.
    @discardableResult
    func recordOnce(_ event: UsageEvent, caseId: String, artifactKind: ArtifactKind? = nil, timed: Bool = false) -> Bool {
        guard recorded.insert("\(caseId)|\(event.rawValue)").inserted else { return false }
        record(UsageRecord(
            event, artifactKind: artifactKind, afterS: timed ? after(caseId: caseId) : nil,
            caseId: attachesAsk ? caseId : nil))
        return true
    }

    /// The bucket for the seconds since `caseId` was opened. An ask with no
    /// recorded open (a deep link) counts as just opened.
    func after(caseId: String) -> UsageAfter {
        guard let start = openedAt[caseId] else { return .s0to2 }
        return UsageAfter(seconds: max(0, clock().timeIntervalSince(start)))
    }
}
