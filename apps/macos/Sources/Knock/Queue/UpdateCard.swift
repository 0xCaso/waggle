import SwiftUI
import AppKit

/// The agent's newest update, shown inside the ask above NEED FROM YOU (HAIL-95, prototype
/// option D). Pure, so when it shows and what it holds are unit-tested.
struct UpdateCardContent: Equatable {
    /// The message with fenced blocks taken out; markdown.
    let prose: String
    /// Shell commands in the message: fenced blocks, the whole message when it is one, and inline code that reads as one.
    let commands: [String]
    let at: Date
    /// Index of the message in `ThreadModel.steps`, for "See conversation".
    let stepIndex: Int

    /// The update to show: the thread's last step, when it is an agent update, so it came after
    /// your last reply and goes away when you reply again. Only on a text ask (the one page
    /// owns an ask with an artifact), and only while the conversation column is out of sight:
    /// an open, wide column already shows it, so the card would repeat it.
    static func content(thread: ThreadModel?, hasArtifact: Bool, isColumnVisible: Bool) -> UpdateCardContent? {
        guard let thread, !hasArtifact, !isColumnVisible,
              let index = thread.steps.indices.last, case .updated(let update) = thread.steps[index],
              !update.message.isEmpty else { return nil }
        let parts = split(update.message)
        return UpdateCardContent(prose: parts.prose, commands: parts.commands, at: update.at, stepIndex: index)
    }

    /// "UPDATE FROM CLAUDE CODE · 21:24".
    static func label(runtime: String, at: Date, timeZone: TimeZone = .current) -> String {
        "UPDATE FROM \(runtime.uppercased()) · \(ThreadCopy.clock(at, timeZone: timeZone))"
    }

    static func split(_ message: String) -> (prose: String, commands: [String]) {
        var commands: [String] = []
        var proseLines: [String] = []
        var fence: [String]?
        for line in message.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let open = fence {
                    let block = open.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !block.isEmpty { commands.append(block) }
                    fence = nil
                } else {
                    fence = []
                }
            } else if fence != nil {
                fence?.append(line)
            } else {
                proseLines.append(line)
            }
        }
        // An unclosed fence keeps what it held as a command.
        if let open = fence {
            let block = open.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !block.isEmpty { commands.append(block) }
        }
        var prose = proseLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if commands.isEmpty, !prose.contains("\n"), isCommand(prose) {
            // The whole message is a command: no prose, only the block.
            return ("", [prose])
        }
        for span in inlineCodeSpans(prose) where isCommand(span) && !commands.contains(span) { commands.append(span) }
        prose = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        return (prose, commands)
    }

    private static func inlineCodeSpans(_ text: String) -> [String] {
        var spans: [String] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "`") {
            let after = rest.index(after: open)
            guard let close = rest[after...].firstIndex(of: "`") else { break }
            let span = rest[after..<close].trimmingCharacters(in: .whitespaces)
            if !span.isEmpty { spans.append(span) }
            rest = rest[rest.index(after: close)...]
        }
        return spans
    }

    private static let commandNames: Set<String> = [
        "git", "bun", "bunx", "npm", "npx", "pnpm", "yarn", "cd", "ls", "cat", "echo", "export", "read", "printf",
        "brew", "swift", "xcodebuild", "claude", "waggle", "knock", "curl", "open", "sudo", "kill", "mkdir", "cp", "mv", "rm",
        "sh", "bash", "zsh", "python", "python3", "node", "docker", "make", "defaults", "chmod", "source", "security",
        "launchctl", "ssh", "scp", "tail", "grep", "sed", "touch", "unset", "env",
    ]

    /// A shell command: a known program first with something after it, a `$ ` prompt, or a chain with `&&`, `|` or `>>`.
    static func isCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("$ ") { return true }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2, let first = words.first else { return false }
        if commandNames.contains(String(first)) { return true }
        return [" && ", " | ", " >> ", " ; "].contains { trimmed.contains($0) }
            && first.allSatisfy { $0.isLetter || $0.isNumber || "-_./".contains($0) }
    }
}
