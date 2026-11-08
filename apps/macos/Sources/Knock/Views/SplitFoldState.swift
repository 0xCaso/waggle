import Foundation
import SwiftUI

/// The fold state of the pages: the queue (left), the question column (right). The conversation
/// column is not saved (WAG-299). "Both folded" (the header's expand icon, HAIL-96) folds the
/// sides to their rails at once and remembers the folds from before, so a second click brings
/// them back. Remembered in `UserDefaults`, so it survives a relaunch (HAIL-84).
@MainActor
final class SplitFoldState: ObservableObject {
    static let queueKey = "knock.split.queueFolded"
    static let askKey = "knock.split.askFolded"
    /// The old full preview flag (HAIL-84). It is read once and removed: see `init`.
    static let legacyFullPreviewKey = "knock.split.fullPreview"
    static let bothFoldedKey = "knock.split.bothFolded"
    static let priorQueueKey = "knock.split.priorQueueFolded"
    static let priorAskKey = "knock.split.priorAskFolded"

    @Published var isQueueFolded: Bool { didSet { defaults.set(isQueueFolded, forKey: Self.queueKey) } }
    @Published var isAskFolded: Bool { didSet { defaults.set(isAskFolded, forKey: Self.askKey) } }
    /// True while both sides are folded by the expand icon and not touched since.
    @Published private(set) var isBothFolded: Bool { didSet { defaults.set(isBothFolded, forKey: Self.bothFoldedKey) } }

    private let defaults: UserDefaults

    /// `KNOCK_SPLIT_FOLD=queue|ask|both|full` (HAIL-84, 89 evidence hook): starts with that fold, so a
    /// harness that cannot click can capture it. Not saved until the operator changes a fold.
    /// `full` folds both sides the way the expand icon does.
    init(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.defaults = defaults
        var queue = defaults.bool(forKey: Self.queueKey)
        var ask = defaults.bool(forKey: Self.askKey)
        var both = defaults.bool(forKey: Self.bothFoldedKey)
        // A saved full preview becomes "both folded": the folds it kept are the ones to restore.
        if defaults.bool(forKey: Self.legacyFullPreviewKey) {
            defaults.removeObject(forKey: Self.legacyFullPreviewKey)
            defaults.set(queue, forKey: Self.priorQueueKey)
            defaults.set(ask, forKey: Self.priorAskKey)
            (queue, ask, both) = (true, true, true)
            defaults.set(true, forKey: Self.queueKey)
            defaults.set(true, forKey: Self.askKey)
            defaults.set(true, forKey: Self.bothFoldedKey)
        }
        switch environment["KNOCK_SPLIT_FOLD"] {
        case "queue": (queue, ask, both) = (true, false, false)
        case "ask": (queue, ask, both) = (false, true, false)
        case "both": (queue, ask, both) = (true, true, false)
        case "full": (queue, ask, both) = (true, true, true)
        default: break
        }
        isQueueFolded = queue
        isAskFolded = ask
        isBothFolded = both
    }

    /// Shows or hides the queue. It ends "both folded": the icon goes back to "fold".
    func toggleQueue() {
        UsageReporter.current?.record(.splitFoldToggled, variantName: "queue")
        isBothFolded = false
        isQueueFolded.toggle()
    }

    /// Shows or hides the question column. It ends "both folded".
    func toggleAsk() {
        UsageReporter.current?.record(.splitFoldToggled, variantName: "ask")
        isBothFolded = false
        isAskFolded.toggle()
    }

    /// The text page's queue fold (HAIL-89). It ends "both folded" too. The conversation column
    /// is not a saved fold any more: it starts closed for every case (WAG-299).
    func toggleQueueFold() { toggleQueue() }

    /// Folds both sides, or brings back the folds the operator had before.
    func toggleBothFolded() {
        UsageReporter.current?.record(.splitFoldToggled, variantName: "both")
        if isBothFolded {
            restoreFolds()
        } else {
            defaults.set(isQueueFolded, forKey: Self.priorQueueKey)
            defaults.set(isAskFolded, forKey: Self.priorAskKey)
            isQueueFolded = true
            isAskFolded = true
            isBothFolded = true
        }
    }

    /// Esc: brings back the earlier folds, and only while both are folded by the icon.
    func exitBothFolded() {
        if isBothFolded { restoreFolds() }
    }

    private func restoreFolds() {
        isQueueFolded = defaults.bool(forKey: Self.priorQueueKey)
        isAskFolded = defaults.bool(forKey: Self.priorAskKey)
        isBothFolded = false
    }
}

/// The header's expand icon (HAIL-96): its symbol and hover label. Pure, so it is unit-tested.
enum BothFoldedCopy {
    static func symbol(isBothFolded: Bool) -> String {
        isBothFolded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
    }

    static func help(isBothFolded: Bool) -> String {
        isBothFolded ? "Show both sides (⌘\\)" : "Fold both sides (⌘\\)"
    }
}

/// The words on the slim strip a folded question column leaves behind. Pure, so it is unit-tested.
enum AskStripCopy {
    static func label(for knockCase: Case) -> String {
        switch knockCase.replyLockState {
        case .editable:
            let count = knockCase.options.count
            if count == 0 { return "Decision" }
            return "Decision · \(count) option\(count == 1 ? "" : "s")"
        case .queued: return "Sent · waiting for the agent"
        case .delivered: return "Delivered"
        case .failed: return "Not delivered"
        }
    }
}

/// The fold keys (HAIL-84). None clashes with the other shortcuts in the app: ⌘0, ⌘1, ⌘+, ⌘=,
/// ⌘- (zoom), ⌘↵ (send), ⌘D, and the bare i, c, arrows, Return and Esc of the artifact stage.
enum SplitFoldShortcuts {
    static let queue = KeyboardShortcut("[", modifiers: .command)
    static let ask = KeyboardShortcut("]", modifiers: .command)
    static let bothFolded = KeyboardShortcut("\\", modifiers: .command)
    /// Esc restores the folds from before, and only while both are folded by the icon.
    static let leaveBothFolded = KeyboardShortcut(.escape, modifiers: [])
}

/// When the queue has something to fold (HAIL-91): it always does, except when Needs you and
/// Answered are both empty. Then there is no icon, no rail and ⌘[ does nothing, whatever fold
/// the operator saved. The saved fold applies again when an ask arrives.
enum QueueFold {
    static func hasContent(needsYouCount: Int, answeredCount: Int) -> Bool {
        needsYouCount > 0 || answeredCount > 0
    }

    /// The fold that shows: the saved one, only while the queue has content.
    static func isFolded(saved: Bool, hasContent: Bool) -> Bool { saved && hasContent }
}
