import Foundation
import SwiftUI

/// WAG-265: keeping agents' questions in Waggle. Two optional rows in Settings › Agents (and the rule
/// card on the last setup screen): the switch for the Claude Code plugin's Stop hook, and the
/// "Add a Waggle rule to your agent instructions" block. Neither is needed to use Waggle.
enum AgentQuestionsCopy {
    static let label = "ASKING IN WAGGLE"
    static let catchTitle = "Catch decisions in the terminal"
    static let catchBody = "When Claude Code ends a turn asking you to decide, it is sent back to Waggle. Needs the Waggle plugin."
    static let ruleTitle = "Add a Waggle rule to your agent instructions"
    static let ruleBody = "Optional. Adds these lines to your global CLAUDE.md (Claude Code) and AGENTS.md (Codex). Nothing is written until you press Add."
    static let codexNote = "Codex has no stop check, so this rule is how it learns to bring decisions to Waggle."
    static let add = "Add"
    static let remove = "Remove"
    static let adding = "Adding"
    static let removing = "Removing"
    static let addFailed = "Could not write the rule. Check that the file can be changed, then try again."
    static let removeFailed = "Could not remove the rule. Try again."
    static let damaged = "The Waggle markers in this file look broken, so Waggle left it alone."
}

/// What `waggle rule status|add|remove` prints: one JSON line.
struct AgentRuleReport: Decodable, Equatable, Sendable {
    struct Agent: Decodable, Equatable, Sendable {
        let path: String
        let present: Bool
        let state: String
    }

    let lines: [String]
    let agents: [String: Agent]

    static func parse(_ line: String) -> AgentRuleReport? {
        try? JSONDecoder().decode(AgentRuleReport.self, from: Data(line.utf8))
    }
}

enum AgentRuleCommand {
    static let status = ["rule", "status"]
    static let add = ["rule", "add"]
    static let remove = ["rule", "remove"]
}

@MainActor
final class AgentRuleModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case adding
        case removing
        case failed(String)
    }

    @Published private(set) var report: AgentRuleReport?
    @Published private(set) var phase: Phase = .idle

    private let runner: OnboardingCommandRunning

    init(runner: OnboardingCommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    var isWorking: Bool { phase == .adding || phase == .removing }

    /// The agents whose config folder exists on this Mac, in a fixed order.
    var presentAgents: [(name: String, agent: AgentRuleReport.Agent)] {
        guard let report else { return [] }
        return ["claude", "codex"].compactMap { name in
            guard let agent = report.agents[name], agent.present else { return nil }
            return (name, agent)
        }
    }

    /// True when every present agent already has the block.
    var isAdded: Bool {
        let present = presentAgents
        return !present.isEmpty && present.allSatisfy { $0.agent.state == "added" }
    }

    var hasDamagedFile: Bool { presentAgents.contains { $0.agent.state == "damaged" } }
    var hasCodex: Bool { presentAgents.contains { $0.name == "codex" } }

    /// Reads the files only. Never writes.
    func refresh() async {
        if let next = await run(AgentRuleCommand.status).report { report = next }
    }

    /// "Add" and "Remove": the only calls that write, and only on a click.
    func set(added wanted: Bool) async {
        guard !isWorking else { return }
        phase = wanted ? .adding : .removing
        let result = await run(wanted ? AgentRuleCommand.add : AgentRuleCommand.remove, only: presentAgents.map(\.name))
        if let next = result.report { report = next }
        await refresh()
        phase = result.code == 0 ? .idle : .failed(wanted ? AgentQuestionsCopy.addFailed : AgentQuestionsCopy.removeFailed)
    }

    private func run(_ command: [String], only agents: [String] = []) async -> (code: Int32, report: AgentRuleReport?) {
        var last: AgentRuleReport?
        let code = await runner.run(command + agents, onLine: { line in
            if let parsed = AgentRuleReport.parse(line) { last = parsed }
        })
        return (code, last)
    }
}

@MainActor
final class CatchQuestionsModel: ObservableObject {
    @Published private(set) var isOn = true
    private let load: () async throws -> Bool
    private let save: (Bool) async throws -> Bool

    init(load: @escaping () async throws -> Bool, save: @escaping (Bool) async throws -> Bool) {
        self.load = load
        self.save = save
    }

    convenience init(client: KnockClient) {
        self.init(
            load: { try await client.catchQuestions() == .on },
            save: { try await client.setCatchQuestions($0 ? .on : .off) == .on })
    }

    func refresh() async {
        // An older daemon has no such key: the switch reads as on, which is also what its hook does.
        isOn = (try? await load()) ?? true
    }

    func set(_ on: Bool) async {
        let previous = isOn
        isOn = on
        if let saved = try? await save(on) { isOn = saved } else { isOn = previous }
    }
}

/// The rule block and its Add / Remove buttons. Shows the exact lines before anything is written.
struct AgentRuleCard: View {
    @ObservedObject var model: AgentRuleModel
    var showsDivider = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCardRow(title: AgentQuestionsCopy.ruleTitle, subtitle: AgentQuestionsCopy.ruleBody, showsDivider: false) {
                HStack(spacing: 10) {
                    switch model.phase {
                    case .adding: LoadingStatus(label: AgentQuestionsCopy.adding)
                    case .removing: LoadingStatus(label: AgentQuestionsCopy.removing)
                    case .idle, .failed: EmptyView()
                    }
                    if model.isAdded {
                        SettingsSecondaryButton(title: AgentQuestionsCopy.remove) { Task { await model.set(added: false) } }
                            .disabled(model.isWorking)
                    } else {
                        SettingsPrimaryButton(title: AgentQuestionsCopy.add) { Task { await model.set(added: true) } }
                            .disabled(model.isWorking || model.presentAgents.isEmpty)
                    }
                }
            }
            preview
            if model.hasCodex { note(AgentQuestionsCopy.codexNote) }
            if model.hasDamagedFile { note(AgentQuestionsCopy.damaged) }
            if case .failed(let message) = model.phase { note(message, isError: true) }
            if showsDivider { Divider().padding(.horizontal, 14) }
        }
        .task { await model.refresh() }
    }

    private var preview: some View {
        let lines = model.report?.lines ?? []
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.presentAgents, id: \.name) { item in
                Text("\(item.agent.state == "added" ? "Added to" : "Goes in") \(item.agent.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.ink3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ text: String, isError: Bool = false) -> some View {
        Text(text)
            .knockTextStyle(Theme.Typography.body12_5w400)
            .foregroundColor(isError ? Theme.Colors.accent : Theme.Colors.ink3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The one new section on Settings › Agents (WAG-265).
struct AgentQuestionsSection: View {
    @StateObject private var catchModel: CatchQuestionsModel
    @StateObject private var ruleModel = AgentRuleModel()

    init(client: KnockClient) {
        _catchModel = StateObject(wrappedValue: CatchQuestionsModel(client: client))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionLabel(AgentQuestionsCopy.label)
            SettingsCard {
                SettingsCardRow(title: AgentQuestionsCopy.catchTitle, subtitle: AgentQuestionsCopy.catchBody, showsDivider: true) {
                    Toggle("", isOn: Binding(get: { catchModel.isOn }, set: { v in Task { await catchModel.set(v) } }))
                        .labelsHidden()
                        .toggleStyle(.switch).pointerCursor()
                }
                AgentRuleCard(model: ruleModel)
            }
        }
        .task { await catchModel.refresh() }
    }
}
