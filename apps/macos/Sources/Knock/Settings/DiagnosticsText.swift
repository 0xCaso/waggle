import Foundation

/// The last N lines of a log file (Help page's "Copy diagnostics", HAIL-52
/// contract: "the last 50 lines of the update log"). `tail` is pure and
/// testable without a real file; `read` is the disk-reading wrapper a real
/// call site uses.
enum UpdateLogTail {
    static func tail(_ lines: [String], keeping n: Int) -> [String] {
        Array(lines.suffix(n))
    }

    static func read(url: URL, keeping n: Int = 50) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return tail(lines, keeping: n)
    }
}

/// Assembles the Help page's "Copy diagnostics" clipboard text (HAIL-52
/// contract: "copies versions (app, daemon, macOS), the `knock doctor`
/// output and the last 50 lines of the update log to the clipboard; no ask
/// content"). Pure and free of the clipboard/network/file calls that gather
/// its inputs, so the assembled shape is testable without a live daemon.
enum DiagnosticsText {
    static func build(
        appVersion: String,
        daemonVersion: String,
        macOSVersion: String,
        doctorLines: [String],
        updateLogLines: [String]
    ) -> String {
        var lines = [
            "Waggle \(appVersion)",
            "Daemon \(daemonVersion)",
            "macOS \(macOSVersion)",
            "",
            "waggle doctor:",
        ]
        lines.append(contentsOf: doctorLines)
        lines.append("")
        lines.append("Update log (last \(updateLogLines.count) lines):")
        lines.append(contentsOf: updateLogLines)
        return lines.joined(separator: "\n")
    }
}
