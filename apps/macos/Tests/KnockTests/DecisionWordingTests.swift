import Testing
import Foundation

/// WAG-275: the app calls what an agent sends a "decision" (a "review" for a review). No string a
/// person reads uses "ask" as the item's name. The agent-facing word stays "ask".
/// WAG-315 (operator decision 8 Oct, Q9): the short UI name is "request", so "request" is allowed as the
/// item's name now. Only "ask" stays banned.
struct DecisionWordingTests {
    /// Lines that talk to the agent, or quote text the agent receives. They keep "ask".
    private static let allowedFragments = [
        "Plan it with me in ONE Waggle plan ask",
        "The human dismissed this ask without answering",
        "\"_tag\": \"Request\"",
        // WAG-314: the agent instructions name the tool's unit, waggle_ask, for agents.
        "Send one ask with items",
    ]

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Knock")
    }

    private static let noun = try! NSRegularExpression(
        pattern: #""[^"\n]*\b(a|an|the|this|that|your|my|its|their|new|test|real|every|each|earlier|answered|finished|no|first|future|short|one|\d+|\\\(count\)|\\\(\w+\)) (ask|asks)\b"#)
    private static let title = try! NSRegularExpression(pattern: #""(Asks)\b[^"]*"|› Asks"#)

    @Test func noUserVisibleStringNamesAnItemAskOrRequest() throws {
        let files = FileManager.default.enumerator(at: Self.sourcesRoot, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let s = String(line)
                if s.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                if Self.allowedFragments.contains(where: s.contains) { continue }
                let range = NSRange(s.startIndex..., in: s)
                // "Request changes" and "Ask for more detail" are verbs the person does, so only nouns match.
                if Self.noun.firstMatch(in: s, range: range) != nil || Self.title.firstMatch(in: s, range: range) != nil,
                   !s.contains("Request changes") {
                    offenders.append("\(file.lastPathComponent):\(index + 1): \(s.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(offenders.isEmpty, "Say \"decision\" or \"review\": \(offenders.joined(separator: "\n"))")
    }
}
