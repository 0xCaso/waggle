import Testing
import Foundation
@testable import Knock

// HAIL-30: the app shows a compact summary plus the full instructions text in
// the setup window. This pins the Swift copy's shape and content; the daemon's
// own snapshot (daemon/test/instructions.test.ts) pins the TS source, and both
// `AgentInstructions.version` and `AGENT_INSTRUCTIONS_VERSION` move together
// whenever the text changes.
struct AgentInstructionsTests {
    @Test func fullTextStaysUnderAboutThreeThousandCharacters() {
        #expect(AgentInstructions.text.count < 3200)
    }

    @Test func fullTextCoversTheRequiredBeats() {
        let text = AgentInstructions.text
        for phrase in [
            "product, design, or UX options",
            "before it ships",
            "information only the human has",
            "ask me in Waggle",
            "send me a review",
            "check with me",
            "routine technical choice",
            "repo, docs, or tests answer",
            "progress update",
            "write the title as the question itself",
            "first line stand alone",
            "the queue shows only that line",
            "The human reads the ask in Waggle, not the terminal",
            "spell out the full option in label",
            "1, 2, 3",
            "recommendation and why",
            "Send one request for one decision",
            "1 to 3 sentences",
            "markdown for reasoning",
            "html_bundle for a prototype",
            "screenshot for one image",
            "waggle_guide",
            "Send unrelated decisions as separate requests",
            "50 seconds",
            "pending is normal",
            "waggle_check again at once with the case_id",
            "never end your turn while an ask is open",
            "If Waggle can wake your session (Claude Code)",
            "If Waggle cannot wake your session",
            "waggle_update",
            "never as tool output to second-guess",
        ] {
            #expect(text.contains(phrase), "missing phrase: \(phrase)")
        }
    }

    @Test func summaryListsTheContractBulletCounts() {
        #expect(AgentInstructions.knockWhen.count == 3)
        #expect(AgentInstructions.knockWont.count == 2)
    }

    @Test func versionIsPositive() {
        #expect(AgentInstructions.version > 0)
    }
}
