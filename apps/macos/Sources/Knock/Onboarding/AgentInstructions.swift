import Foundation

/// The "Your agents now know how to use Waggle" panel content (HAIL-29), read from
/// the one copy of the agent instructions the app carries (HAIL-30,
/// `AgentInstructionsPanel.swift`, kept identical to the daemon's
/// `MCP_INSTRUCTIONS` by daemon/test/instructions.test.ts).
extension AgentInstructions {
    /// The panel's two-column summary: three "knock when" bullets, two "won't".
    static func agentInstructionsSummary() -> AgentInstructionsSummary {
        AgentInstructionsSummary(knocksWhen: knockWhen, wont: knockWont)
    }

    /// The exact text agents receive on initialize.
    static func agentInstructionsFullText() -> String {
        text
    }
}

/// The panel's summary, split into the two labeled columns the design shows
/// ("THEY COME TO YOU WHEN…" / "THEY WON'T…").
struct AgentInstructionsSummary: Equatable {
    let knocksWhen: [String]
    let wont: [String]
}
