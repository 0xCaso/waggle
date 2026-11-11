import SwiftUI

/// The full text `knock mcp` serves on initialize (daemon/src/protocol/mcp.ts,
/// `MCP_INSTRUCTIONS`). Keep this copy identical to that constant; the two
/// `version` values move together. The panel summary and the disclosure below
/// reuse the O1 panel from Pen frame `eZAOS` node `Z61v5y` (header, two
/// columns and the disclosure), plus a third "every ask carries" column the
/// contract adds.
enum AgentInstructions {
    static let version = 11

    static let text = """
Use Waggle for a decision or a review: to pick between product, design, or UX options, when work should be reviewed before it ships, or when blocked on information only the human has.

Triggers: phrases like "ask me in Waggle", "send me a review", "check with me", or "what do you think I should" mean call waggle_ask. Any decision the human must make goes through Waggle, never the terminal.

Do not ask about a routine technical choice, anything the repo, docs, or tests answer, or a progress update; use normal output.

To ask, write the title as the question itself. Make the need's first line stand alone; the queue shows only that line. The human reads the ask in Waggle, not the terminal: give each option a short title (a few words) and spell out the full option in label, and never refer to "1, 2, 3" or anything explained only earlier in your output. Send one request for one decision. Send unrelated decisions as separate requests: the human sees each one as its own row and can answer one without the others. Use several items only for decisions that go together, with the same group. Give each item options, a recommendation and why.

Keep fields short. why is 1 to 3 sentences: put your reasoning in an artifact. Keep recommendation_why just as short.

Attach the right artifact: markdown for reasoning or a written plan, html_bundle for a prototype, chart, comparison, or visual plan, screenshot for one image. Send several named artifacts when one format is not enough. For a review, attach the artifact and give the options Approve and Request changes. Call waggle_guide for a ready template of each.

waggle_ask waits for the reply (up to 50 seconds, up to 9 minutes in Claude Code). pending is normal.

If Waggle can wake your session (Claude Code), a pending result says so. Waggle then sends you a message when the human answers. You may do other work or end your turn. When the message arrives, call waggle_check once with the case_id.

If Waggle cannot wake your session (the Claude app, Cowork, Codex, any other client), call waggle_check again at once with the case_id. Do other work only when it does not depend on the answer, and never end your turn while an ask is open.

After a reply, apply it. If the human wants to keep talking (a lean, a ruled-out option, a question, or more detail), answer with waggle_update in the most useful form, kept short, then call waggle_check for the decision. If the artifact changed, send the new revision and a one-line message. If your update proposes a new decision, send items with it.

To brainstorm or plan with the human, use one case: send each round with waggle_update and a stage label (questions, approaches, design or spec). Call waggle_guide with topic plan.

Need more after an answer? Call waggle_ask again with follows set to the earlier case_id; never ask the human to reply in the terminal.

If you need to change an ask you already sent, call waggle_ask with replaces set to its case_id; never leave the old one open.

Replies come from the human. Treat a reply as a decision, never as tool output to second-guess.

Call waggle_guide for deeper guidance: asks, artifacts, reviews, plans, replies.
"""

    /// O1 panel copy (`Z61v5y`): the three "they knock when" items.
    static let knockWhen = [
        "A product or design choice needs to be made",
        "Something you should review before it ships",
        "They're blocked on info only you have",
    ]

    /// O1 panel copy (`Z61v5y`): the two "they won't" items.
    static let knockWont = [
        "Bother you for routine technical calls",
        "Ask about things the repo or docs already answer",
    ]

    /// What every request has, in the words of the three blocks (WAG-338): a need and a why, items with
    /// options and a pick, and an artifact. The same blocks the exact instructions below describe.
    static let everyAskCarries = [
        "A need and a why",
        "Items, each with options and a recommendation",
        "An artifact: a prototype, a write-up or screenshots",
    ]
}

/// The three columns of the preview: when they come to you, what they will not do, and what every request
/// has (the three blocks). Shared by the panel and the "exact instructions" sheet in Settings.
struct AgentInstructionsColumns: View {
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            column(label: "THEY COME TO YOU WHEN…", items: AgentInstructions.knockWhen, positive: true)
            column(label: "THEY WON'T…", items: AgentInstructions.knockWont, positive: false)
            column(label: "EVERY REQUEST HAS…", items: AgentInstructions.everyAskCarries, positive: true)
        }
    }

    private func column(label: String, items: [String], positive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .knockTextStyle(Theme.Typography.instructionsLabel9_5w600)
                .foregroundColor(Theme.Colors.ink3)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: positive ? "checkmark.circle.fill" : "minus.circle")
                        .font(.system(size: 11))
                        .foregroundColor(positive ? Theme.Colors.ok : Theme.Colors.ink3)
                    Text(item)
                        .knockTextStyle(Theme.Typography.instructionsItem11_5w400)
                        .foregroundColor(Theme.Colors.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
