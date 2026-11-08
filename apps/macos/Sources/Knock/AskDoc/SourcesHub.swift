import SwiftUI

/// The state of the sources on one request page (WAG-356): the round's sources, the card at a pill (shown by
/// hover, kept by a click), and the Sources list at the right edge. One card at a time.
@MainActor
final class SourcesHub: ObservableObject {
    /// A pill the card hangs under: which pill, what it cites, and where it is in the host's space.
    struct Anchor: Equatable {
        let key: String
        let ids: [String]
        var rect: CGRect
    }

    static let space = "sourcesHost"
    static let hoverDelay: Duration = .milliseconds(150)
    static let leaveDelay: Duration = .milliseconds(120)
    static let cardWidth: CGFloat = 340
    static let panelWidth: CGFloat = 380

    @Published private(set) var book: SourceBook
    @Published private(set) var hover: Anchor?
    @Published private(set) var pinned: Anchor?
    @Published private(set) var isListOpen = false
    @Published private(set) var openRowId: String?

    /// The host's size, for "click outside the list" and for keeping the card inside the window.
    var hostSize: CGSize = .zero
    /// Where the card is drawn, in the host's space.
    var cardRect: CGRect = .zero
    /// Where each pill is, so a click on a pill is not "outside".
    private(set) var pillRects: [String: CGRect] = [:]
    /// The click area of each pill (WAG-359): its shape plus the room around it.
    private(set) var pillHitRects: [String: CGRect] = [:]

    private var showTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var pointerOnCard = false

    /// Evidence only (`KNOCK_EVIDENCE_SOURCES_OPEN`): `pin:<source id>` pins the first pill that cites it,
    /// `list` or `list:<source id>` opens the list.
    let evidenceOpen: String?

    init(book: SourceBook = .empty, evidenceOpen: String? = nil) {
        self.book = book
        self.evidenceOpen = evidenceOpen
        if let evidenceOpen, evidenceOpen.hasPrefix("list") {
            isListOpen = true
            openRowId = evidenceOpen.hasPrefix("list:") ? String(evidenceOpen.dropFirst(5)) : nil
        }
    }

    /// The card on screen: the pinned one, else the one under the pointer.
    var shown: Anchor? { pinned ?? hover }
    var isPinnedShown: Bool { pinned != nil }
    var isOpen: Bool { shown != nil || isListOpen }

    func update(book: SourceBook) {
        guard book != self.book else { return }
        self.book = book
        if let shown, book.pill(ids: shown.ids) == nil { pinned = nil; hover = nil }
        if let openRowId, book.source(id: openRowId) == nil { self.openRowId = nil }
        if book.isEmpty { isListOpen = false }
    }

    // MARK: Pills

    /// Counts the reports that changed a stored rect. Tests read it.
    private(set) var reportWrites = 0

    func setHostSize(_ size: CGSize) {
        guard !Self.same(hostSize, size) else { return }
        hostSize = size
    }

    /// Half a point is the same place (WAG-365). A report of the same place writes nothing, so a layout pass that
    /// reports each pill again cannot start another pass.
    func report(key: String, rect: CGRect, hit: CGRect? = nil) {
        let hit = hit ?? rect
        if let old = pillRects[key], let oldHit = pillHitRects[key], Self.same(old, rect), Self.same(oldHit, hit) { return }
        EvidenceLayoutLog.event("pill.report.write", "\(EvidenceLayoutLog.safe(key)) old=\(String(describing: pillRects[key])) new=\(rect)")
        reportWrites += 1
        pillRects[key] = rect
        pillHitRects[key] = hit
        if pinned?.key == key { pinned?.rect = rect }
        if hover?.key == key { hover?.rect = rect }
    }

    private static func same(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) <= AskCommentsUI.tolerance && abs(a.height - b.height) <= AskCommentsUI.tolerance
    }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= AskCommentsUI.tolerance && abs(a.minY - b.minY) <= AskCommentsUI.tolerance
            && same(a.size, b.size)
    }

    func forget(key: String) {
        pillRects[key] = nil
        pillHitRects[key] = nil
        if pinned?.key == key { pinned = nil }
        if hover?.key == key { hover = nil }
    }

    func pointerMoved(onPill key: String, ids: [String], inside: Bool) {
        EvidenceLayoutLog.event("pill.pointer", "\(EvidenceLayoutLog.safe(key)) inside=\(inside)")
        if inside {
            hideTask?.cancel()
            // A pinned card stays until it is closed: hovering another pill does not replace it.
            guard pinned == nil, hover?.key != key else { return }
            showTask?.cancel()
            showTask = Task { [weak self] in
                try? await Task.sleep(for: Self.hoverDelay)
                guard !Task.isCancelled, let self, let rect = self.pillRects[key] else { return }
                self.hover = Anchor(key: key, ids: ids, rect: rect)
            }
        } else {
            showTask?.cancel()
            scheduleHide()
        }
    }

    func pointerMoved(onCard inside: Bool) {
        pointerOnCard = inside
        if inside { hideTask?.cancel() } else { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.leaveDelay)
            guard !Task.isCancelled, let self, !self.pointerOnCard else { return }
            self.hover = nil
        }
    }

    /// A click on a pill: pins its card, or closes it when it is the pinned one.
    func tap(key: String, ids: [String]) {
        EvidenceLayoutLog.event("pill.tap", "\(EvidenceLayoutLog.safe(key))")
        showTask?.cancel()
        hideTask?.cancel()
        if pinned?.key == key {
            pinned = nil
            hover = nil
        } else if let rect = pillRects[key] {
            UsageReporter.current?.record(.sourceOpened)
            pinned = Anchor(key: key, ids: ids, rect: rect)
            hover = nil
        }
    }

    /// Keeps the card that shows now open, so the person can select its words and comment on them.
    func holdShownCard() {
        guard pinned == nil, let hover else { return }
        hideTask?.cancel()
        pinned = hover
        self.hover = nil
    }

    func isPinned(key: String) -> Bool { pinned?.key == key }

    // MARK: Closing

    /// Escape: closes the card, else the list. False when nothing was open.
    @discardableResult
    func dismissTopmost() -> Bool {
        if pinned != nil || hover != nil {
            pinned = nil
            hover = nil
            return true
        }
        if isListOpen {
            closeList()
            return true
        }
        return false
    }

    /// A click anywhere in the host that no pill, card or panel took.
    func clickedOutside(at point: CGPoint) {
        if pinned != nil, !cardRect.contains(point), !pillHitRects.values.contains(where: { $0.contains(point) }) {
            pinned = nil
        }
        if isListOpen, point.x < hostSize.width - Self.panelWidth { closeList() }
    }

    // MARK: List

    func openList(selecting id: String? = nil) {
        UsageReporter.current?.record(.sourcesListOpened)
        pinned = nil
        hover = nil
        openRowId = id
        withAnimation(Self.listAnimation(opening: true)) { isListOpen = true }
    }

    func closeList() {
        withAnimation(Self.listAnimation(opening: false)) { isListOpen = false }
    }

    func toggleRow(_ id: String) {
        openRowId = openRowId == id ? nil : id
    }

    /// Enter 220 ms ease-out; exit faster. Reduce Motion: none.
    static func listAnimation(opening: Bool) -> Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: opening ? 0.22 : 0.14)
    }
}

private struct SourcesHubKey: EnvironmentKey {
    static let defaultValue: SourcesHub? = nil
}

extension EnvironmentValues {
    /// The sources of the request page on screen. `nil` outside it: agent text shows no pills there.
    var sourcesHub: SourcesHub? {
        get { self[SourcesHubKey.self] }
        set { self[SourcesHubKey.self] = newValue }
    }
}

/// Evidence only (WAG-356): `KNOCK_EVIDENCE_SOURCES=<json file>` gives the sources of the cases it names, by
/// title (`{"Case title": [source, ...]}`), for a daemon that does not serve `sources` yet. It works only in a
/// process whose `KNOCK_BUNDLE_ID` starts with `dev.limone.knock.evidence`, and never replaces sources a daemon sent.
enum EvidenceSources {
    private static let overlay: [String: [Source]] = {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["KNOCK_EVIDENCE_SOURCES"],
              environment["KNOCK_BUNDLE_ID"]?.hasPrefix("dev.limone.knock.evidence") == true,
              let data = FileManager.default.contents(atPath: path),
              let map = try? JSONDecoder().decode([String: LossyList<Source>].self, from: data) else { return [:] }
        return map.mapValues(\.elements)
    }()

    static func sources(forTitle title: String) -> [Source] { overlay[title] ?? [] }

    static var open: String? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KNOCK_BUNDLE_ID"]?.hasPrefix("dev.limone.knock.evidence") == true else { return nil }
        return environment["KNOCK_EVIDENCE_SOURCES_OPEN"]
    }
}
