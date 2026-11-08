import Combine
import SwiftUI

/// WAG-320: the last version of an artifact this person opened, per case and artifact name, kept in
/// `UserDefaults` like the other per-viewer state. It gives the "Changes since vN" baseline.
struct ArtifactSeenRecord: Codable, Equatable {
    /// The newest version opened.
    var seen: Int
    /// The version that was the newest opened one before `baseFor` first opened.
    var base: Int?
    var baseFor: Int?
    /// The surfaces ("box", "full") where `baseFor` already opened at its first change. Before WAG-408 the first
    /// open wrote it, so an old record holds it on nearly every write-up: it never means "changes off".
    var dismissed: [String] = []
    /// WAG-408: the surfaces where the person turned the changes off for `baseFor`. Absent in an old record.
    var hidden: [String]?
}

struct ArtifactSeenStore: @unchecked Sendable {
    static let shared = ArtifactSeenStore()
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ caseId: String, _ artifact: String) -> String { "waggle.writeUpSeen.\(caseId).\(artifact)" }

    func record(caseId: String, artifact: String) -> ArtifactSeenRecord? {
        defaults.data(forKey: key(caseId, artifact)).flatMap { try? JSONDecoder().decode(ArtifactSeenRecord.self, from: $0) }
    }

    private func save(_ record: ArtifactSeenRecord, caseId: String, artifact: String) {
        if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: key(caseId, artifact)) }
    }

    /// Opening `revision` records it as seen. A newer version than the one seen keeps the old one as the
    /// baseline. Opening an older one changes nothing. `isFirstTime` stays true for a new version on a surface
    /// until that surface scrolled to the first change (`markScrolled`). Opening alone never ends it, so a
    /// view that SwiftUI builds twice cannot use it up. `isOn` is false once the person turned the changes off
    /// on that surface (`dismiss`) and stays false until they turn them on (`enable`) or a new version comes.
    func open(caseId: String, artifact: String, revision: Int, surface: String) -> (base: Int?, isFirstTime: Bool, isOn: Bool) {
        // `KNOCK_EVIDENCE_SEEN=<n>` (WAG-320 evidence hook): a first open counts as if v<n> was seen before.
        let evidenceSeen = ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_SEEN"].flatMap(Int.init)
        guard var record = record(caseId: caseId, artifact: artifact) ?? evidenceSeen.map({ ArtifactSeenRecord(seen: $0) }) else {
            save(ArtifactSeenRecord(seen: revision), caseId: caseId, artifact: artifact)
            return (nil, false, true)
        }
        if revision > record.seen {
            record.base = record.seen
            record.baseFor = revision
            record.seen = revision
            record.dismissed = []
            record.hidden = nil
        }
        guard record.baseFor == revision, let base = record.base else {
            save(record, caseId: caseId, artifact: artifact)
            return (nil, false, true)
        }
        save(record, caseId: caseId, artifact: artifact)
        return (base, !record.dismissed.contains(surface), !(record.hidden ?? []).contains(surface))
    }

    /// Whether the changes show on `surface` for `revision`: on unless the person turned them off for it.
    func isOn(caseId: String, artifact: String, revision: Int, surface: String) -> Bool {
        guard let record = record(caseId: caseId, artifact: artifact), record.baseFor == revision else { return true }
        return !(record.hidden ?? []).contains(surface)
    }

    /// The person turned the changes off on `surface`: the next open of this version shows the plain text.
    func dismiss(caseId: String, artifact: String, surface: String) {
        guard var record = record(caseId: caseId, artifact: artifact), !(record.hidden ?? []).contains(surface) else { return }
        record.hidden = (record.hidden ?? []) + [surface]
        save(record, caseId: caseId, artifact: artifact)
    }

    /// The person turned the changes back on for `surface`.
    func enable(caseId: String, artifact: String, surface: String) {
        guard var record = record(caseId: caseId, artifact: artifact), (record.hidden ?? []).contains(surface) else { return }
        record.hidden?.removeAll { $0 == surface }
        save(record, caseId: caseId, artifact: artifact)
    }

    /// `surface` scrolled to the first change of this version: later opens do not.
    func markScrolled(caseId: String, artifact: String, surface: String) {
        guard var record = record(caseId: caseId, artifact: artifact), !record.dismissed.contains(surface) else { return }
        record.dismissed.append(surface)
        save(record, caseId: caseId, artifact: artifact)
    }
}

/// WAG-320: what the "Changes since vN" toggle of a write-up needs. Pure.
struct WriteUpChangesPlan: Equatable {
    let base: Int
    /// Opens scrolled to the first change: a version the person has not seen, the first time.
    let opensAtFirstChange: Bool

    /// `nil` when there is nothing to compare: one version only, or the shown one is not the newest.
    /// `lastSeenBase` is the baseline the store holds for `shown`; unknown, the previous version counts.
    static func make(revisions: [Int], shown: Int, lastSeenBase: Int?, isFirstTime: Bool) -> WriteUpChangesPlan? {
        let sorted = revisions.sorted()
        guard sorted.count > 1, sorted.last == shown else { return nil }
        let previous = sorted.last { $0 < shown }
        let base = lastSeenBase.flatMap { sorted.contains($0) && $0 < shown ? $0 : nil } ?? previous
        guard let base else { return nil }
        return WriteUpChangesPlan(base: base, opensAtFirstChange: lastSeenBase != nil && isFirstTime)
    }
}

/// WAG-321: the changes of a diff as a list to step through. Pure.
struct WriteUpChangeList: Equatable {
    /// Positions in `WriteUpDiff.Result.entries` of every changed, added, removed or moved block, in order.
    let positions: [Int]

    init(result: WriteUpDiff.Result) {
        positions = result.entries.enumerated().filter { $0.element.change != .unchanged }.map(\.offset)
    }

    var count: Int { positions.count }

    /// "3 changes since v7".
    func title(since base: Int) -> String { "\(count) \(count == 1 ? "change" : "changes") since v\(base)" }

    /// The change to jump to from change `current` (`nil`: none yet). Wraps at both ends. `nil` with no changes.
    func step(from current: Int?, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return forward ? 0 : count - 1 }
        return ((current + (forward ? 1 : -1)) % count + count) % count
    }
}

/// A scroll or a flash aimed at one block. The token makes a repeat of the same block a new request.
struct WriteUpBlockRequest: Equatable {
    let entry: Int
    let token: Int
}

/// One write-up's changes state, shared by the case page box and full size (each has its own).
@MainActor
final class WriteUpChangesModel: ObservableObject {
    let plan: WriteUpChangesPlan?
    @Published private(set) var result: WriteUpDiff.Result?
    @Published private(set) var failed = false
    /// The change the last up or down press reached (its place in `changeList`), `nil` before the first press.
    @Published private(set) var current: Int?
    @Published private(set) var scrollRequest: WriteUpBlockRequest?
    @Published private(set) var flashRequest: WriteUpBlockRequest?

    private let caseId: String
    private let artifact: String
    private let surface: String
    private let store: ArtifactSeenStore
    private let shown: Int
    private let newText: String
    private let client: KnockClient?
    private var token = 0
    private var didOpenAtFirst = false
    /// WAG-408: the person's "Show changes" switch. Off shows the plain latest version.
    @Published private(set) var isOn = true

    init(caseId: String, artifact: String, revisions: [Int], shown: Int, newText: String, surface: String,
         client: KnockClient, store: ArtifactSeenStore = .shared) {
        self.caseId = caseId
        self.artifact = artifact
        self.surface = surface
        self.store = store
        self.shown = shown
        self.newText = newText
        self.client = client
        let opened = store.open(caseId: caseId, artifact: artifact, revision: shown, surface: surface)
        self.plan = WriteUpChangesPlan.make(revisions: revisions, shown: shown, lastSeenBase: opened.base, isFirstTime: opened.isFirstTime)
        self.isOn = opened.isOn
    }

    /// For tests: a model with its diff already known.
    init(plan: WriteUpChangesPlan, result: WriteUpDiff.Result, store: ArtifactSeenStore) {
        self.caseId = "case"
        self.artifact = "artifact"
        self.surface = "box"
        self.store = store
        self.shown = plan.base + 1
        self.newText = ""
        self.client = nil
        self.plan = plan
        self.result = result
        self.isOn = store.isOn(caseId: caseId, artifact: artifact, revision: shown, surface: surface)
    }

    var changeList: WriteUpChangeList? { result.map { WriteUpChangeList(result: $0) } }

    /// The inline view shows when the older version loaded and something changed. No change, one version
    /// or a failed load: the plain write-up shows, with no count and no buttons.
    var hasChanges: Bool { plan != nil && !failed && (changeList?.count ?? 0) > 0 }

    /// The inline view shows when there are changes and the switch is on. Off: the plain latest version.
    var showsInline: Bool { hasChanges && isOn }

    /// "3 changes since v7", for the header. Hidden with the switch off.
    var countTitle: String? {
        guard showsInline, let plan, let list = changeList else { return nil }
        return list.title(since: plan.base)
    }

    func setShowChanges(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        if on {
            store.enable(caseId: caseId, artifact: artifact, surface: surface)
        } else {
            store.dismiss(caseId: caseId, artifact: artifact, surface: surface)
        }
    }

    func load() async {
        guard let plan, result == nil else { return }
        guard let path = try? await client?.artifactPath(caseId: caseId, revision: plan.base),
              path.kind == .markdown,
              let old = try? String(contentsOfFile: path.root, encoding: .utf8) else {
            failed = true
            return
        }
        result = WriteUpDiff.diff(old: old, new: newText)
    }

    func next() { go(forward: true) }
    func previous() { go(forward: false) }

    private func go(forward: Bool) {
        guard let list = changeList, let target = list.step(from: current, forward: forward) else { return }
        current = target
        token += 1
        let request = WriteUpBlockRequest(entry: list.positions[target], token: token)
        scrollRequest = request
        flashRequest = request
    }

    /// A new version opens scrolled to its first change, the first time it is seen. Called once the inline
    /// view is on screen. It uses the first-time state up, so it does not repeat on a later open.
    func openAtFirstChangeIfNeeded() {
        guard !didOpenAtFirst, isOn, plan?.opensAtFirstChange == true, let list = changeList, let first = list.positions.first else { return }
        didOpenAtFirst = true
        current = 0
        token += 1
        scrollRequest = WriteUpBlockRequest(entry: first, token: token)
        store.markScrolled(caseId: caseId, artifact: artifact, surface: surface)
    }
}

/// The header of a write-up box looks at the model of the write-up on show: the host sets it, the header
/// reads it. One per surface (the case page box, full size).
@MainActor
final class WriteUpChangesHub: ObservableObject {
    @Published private(set) var active: WriteUpChangesModel?
    private var remembered: (key: String, model: WriteUpChangesModel)?

    /// WAG-380: the model of one write-up (case, artifact, shown version, surface). A host that SwiftUI builds
    /// again for the same write-up gets the same model back, so `activate` finds it already active and publishes
    /// nothing. A new write-up replaces the one kept.
    func model(for key: String, make: () -> WriteUpChangesModel) -> WriteUpChangesModel {
        if let remembered, remembered.key == key { return remembered.model }
        let model = make()
        remembered = (key, model)
        return model
    }

    func activate(_ model: WriteUpChangesModel) {
        EvidenceLayoutLog.event("changes.activate", "hub=\(ObjectIdentifier(self).hashValue % 9973) model=\(ObjectIdentifier(model).hashValue % 9973) same=\(active === model)")
        if active !== model { active = model }
    }

    func deactivate(_ model: WriteUpChangesModel) {
        EvidenceLayoutLog.event("changes.deactivate", "hub=\(ObjectIdentifier(self).hashValue % 9973) model=\(ObjectIdentifier(model).hashValue % 9973) same=\(active === model)")
        if active === model { active = nil }
    }
}

/// Wraps a write-up: owns the changes model, loads the older version, hands it to `content`.
struct WriteUpChangesHost<Content: View>: View {
    @StateObject private var model: WriteUpChangesModel
    private let hub: WriteUpChangesHub?
    private let content: (WriteUpChangesModel) -> Content

    init(caseId: String, artifact: String, revisions: [Int], shown: Int, text: String, surface: String,
         client: KnockClient, hub: WriteUpChangesHub? = nil, @ViewBuilder content: @escaping (WriteUpChangesModel) -> Content) {
        let make = {
            WriteUpChangesModel(
                caseId: caseId, artifact: artifact, revisions: revisions, shown: shown, newText: text, surface: surface, client: client)
        }
        let key = "\(caseId)|\(artifact)|\(shown)|\(surface)"
        _model = StateObject(wrappedValue: hub?.model(for: key, make: make) ?? make())
        self.hub = hub
        self.content = content
    }

    var body: some View {
        content(model)
            .task { await model.load() }
            .onAppear { hub?.activate(model) }
            .onDisappear { hub?.deactivate(model) }
    }
}
