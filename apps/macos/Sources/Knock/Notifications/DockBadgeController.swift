import AppKit
import Combine

/// The red badge on Knock's Dock icon (HAIL-78): the Needs you count, the same
/// number the menu bar item shows (`AppModel.needsYouCases.count`, one source).
/// Nothing at 0. It only follows the model, so while the daemon is offline the
/// badge keeps the last count fetched (the lists are kept until a fresh fetch).
@MainActor
final class DockBadgeController {
    /// `nil` clears the badge (0), "99+" caps a long queue.
    nonisolated static func label(for count: Int) -> String? {
        if count <= 0 { return nil }
        return count > 99 ? "99+" : String(count)
    }

    private let apply: (String?) -> Void
    private var cancellable: AnyCancellable?

    /// `counts` emits the Needs you count (current value first). `apply`
    /// defaults to `NSApp.dockTile.badgeLabel`; tests pass their own.
    init(
        counts: some Publisher<Int, Never>,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        apply: ((String?) -> Void)? = nil
    ) {
        let logPath = environment["KNOCK_EVIDENCE_DOCK_BADGE_LOG"]
        let setLabel = apply ?? { NSApp.dockTile.badgeLabel = $0 }
        self.apply = setLabel
        cancellable = counts.removeDuplicates().sink { count in
            let label = Self.label(for: count)
            setLabel(label)
            // Evidence hook: the Dock is outside the window and must not be
            // captured, so a test copy logs the label it read back.
            if let logPath {
                let readBack = apply == nil ? NSApp.dockTile.badgeLabel : label
                let line = "count=\(count) badge=\(readBack ?? "<none>")\n"
                if let handle = FileHandle(forWritingAtPath: logPath) ?? {
                    FileManager.default.createFile(atPath: logPath, contents: nil)
                    return FileHandle(forWritingAtPath: logPath)
                }() {
                    handle.seekToEndOfFile()
                    handle.write(Data(line.utf8))
                    try? handle.close()
                }
            }
        }
    }
}
