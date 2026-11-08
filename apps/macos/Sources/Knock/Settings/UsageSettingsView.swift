import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The words and numbers of the Usage section (HAIL-195). Pure, so the share and token formats are
/// testable without a live daemon. Every number is an estimate.
enum UsageText {
    static let inside =
        "Waggle keeps a private list of your agent's Waggle tool calls: which tool, when, how long, how big, and an estimated token count. It also counts what you click, with no text of your decisions, replies or files. Nothing leaves your Mac until you send the exported file."

    static func share(_ value: Double?) -> String {
        guard let value else { return "-" }
        return "\(Int((value * 100).rounded()))%"
    }

    static func tokens(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic))
    }

    static func daysLabel(_ days: Int) -> String {
        days == 1 ? "last day" : "last \(days) days"
    }

    static func totalLine(_ summary: UsageSummary) -> String {
        guard summary.calls > 0 else { return "No tool calls yet" }
        let noun = summary.calls == 1 ? "call" : "calls"
        return "\(summary.calls) \(noun) · \(tokens(summary.tokensWritten + summary.tokensReceived + summary.contextTokens)) tokens · \(daysLabel(summary.days))"
    }

    static func toolLine(_ row: UsageToolRow) -> String {
        var line = "\(row.calls) \(row.calls == 1 ? "call" : "calls") · \(tokens(row.tokensWritten)) written · \(tokens(row.tokensReceived)) received"
        if row.contextTokens > 0 { line += " · \(tokens(row.contextTokens)) re-read" }
        return line
    }

    static func waitLine(_ summary: UsageSummary) -> String {
        guard summary.waitCalls > 0 else { return "No checks yet" }
        let minutes = Int((summary.waitedS / 60).rounded())
        return "\(summary.waitCalls) \(summary.waitCalls == 1 ? "check" : "checks") · \(share(summary.waitShare)) of the tokens · \(minutes) min waiting for you"
    }

    static func sessionLine(_ row: UsageSessionRow) -> String {
        "\(row.clientName ?? "Unknown client") · \(row.calls) \(row.calls == 1 ? "call" : "calls") · \(tokens(row.tokens)) tokens"
    }

    static func estimateLine(_ summary: UsageSummary) -> String {
        "Token counts are estimates. About \(summary.bytesPerToken) bytes per token and \(tokens(summary.tokensPerImage)) tokens per image."
    }

    /// The hint under "Include my notes and comments in the export" (WAG-366). Off by default.
    static let exportTextHint =
        "Off by default. When on, the exported file also holds the text of the notes and comments you sent. Nothing leaves your Mac until you send the file."

    /// The line under "Export usage" after a save. It says so when the file holds text.
    static func exported(toolCalls: Int, notes: Int, file: String) -> String {
        let text = notes > 0 ? " It holds the text of \(notes) \(notes == 1 ? "reply" : "replies")." : ""
        return "Saved \(toolCalls) tool calls to \(file), with a CSV beside it.\(text) Nothing has been sent."
    }

    static func exportFileName(on date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "waggle-usage-\(formatter.string(from: date)).json"
    }
}

/// Holds the Usage section's numbers and switches. The daemon owns the data and the switches; this
/// only reads them and sends changes. Polls like the rest of the Data & privacy page.
@MainActor
final class UsageSettingsModel: ObservableObject {
    @Published private(set) var summary: UsageSummary?
    @Published private(set) var exportNote: String?
    @Published private(set) var isBusy = false

    private let client: KnockClient
    private let days: Int
    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?

    init(client: KnockClient, days: Int = 7, pollInterval: Duration = .seconds(10)) {
        self.client = client
        self.days = days
        self.pollInterval = pollInterval
    }

    func start() async {
        guard pollTask == nil else { return }
        await load()
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                await self?.load()
            }
        }
    }

    func load() async {
        if let next = try? await client.usageSummary(days: days) { summary = next }
    }

    func setRecord(_ on: Bool) async {
        _ = try? await client.usageControl(UsageControlParams(record: on))
        await load()
    }

    func setTranscript(_ on: Bool) async {
        _ = try? await client.usageControl(UsageControlParams(transcript: on))
        await load()
    }

    func setExportText(_ on: Bool) async {
        _ = try? await client.usageControl(UsageControlParams(exportText: on))
        await load()
    }

    func deleteAll() async {
        isBusy = true
        _ = try? await client.usageControl(UsageControlParams(delete: true))
        exportNote = nil
        await load()
        isBusy = false
    }

    func export(to url: URL) async {
        isBusy = true
        if let result = try? await client.usageExport(path: url.path) {
            exportNote = UsageText.exported(toolCalls: result.toolCalls, notes: result.notes ?? 0, file: url.lastPathComponent)
            UsageReporter.current?.record(.usageExported)
        } else {
            exportNote = "The export did not work. Try again."
        }
        isBusy = false
    }
}

/// The "Usage" section of Settings › Data & privacy (HAIL-195).
struct UsageSettingsSection: View {
    @StateObject private var model: UsageSettingsModel
    @State private var showsDeleteConfirmation = false

    init(client: KnockClient) {
        _model = StateObject(wrappedValue: UsageSettingsModel(client: client))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionLabel("USAGE")
            Text(UsageText.inside)
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(Theme.Colors.ink3)
                .fixedSize(horizontal: false, vertical: true)

            SettingsCard {
                SettingsCardRow(
                    title: "Record usage on this Mac",
                    subtitle: "On by default. It stays on this Mac, and rows older than \(model.summary?.retentionDays ?? 90) days are deleted.",
                    showsDivider: true
                ) {
                    Toggle("", isOn: Binding(get: { model.summary?.record ?? true }, set: { v in Task { await model.setRecord(v) } }))
                        .labelsHidden()
                        .toggleStyle(.switch).pointerCursor()
                }
                SettingsCardRow(
                    title: "Measure token use from my agent's session log",
                    subtitle: "Reads only the token counts of the agent's latest message, never what it says.",
                    showsDivider: true
                ) {
                    Toggle("", isOn: Binding(get: { model.summary?.transcript ?? true }, set: { v in Task { await model.setTranscript(v) } }))
                        .labelsHidden()
                        .toggleStyle(.switch).pointerCursor()
                        .disabled(model.summary?.record == false)
                }
                SettingsCardRow(
                    title: "Include my notes and comments in the export",
                    subtitle: UsageText.exportTextHint,
                    showsDivider: false
                ) {
                    Toggle("", isOn: Binding(get: { model.summary?.exportText ?? false }, set: { v in Task { await model.setExportText(v) } }))
                        .labelsHidden()
                        .toggleStyle(.switch).pointerCursor()
                }
            }

            if let summary = model.summary {
                SettingsCard {
                    SettingsCardRow(
                        title: "Tool calls",
                        subtitle: UsageText.totalLine(summary),
                        showsDivider: true
                    ) { EmptyView() }
                    ForEach(summary.tools, id: \.tool) { row in
                        SettingsCardRow(title: row.tool, subtitle: UsageText.toolLine(row), showsDivider: true) { EmptyView() }
                    }
                    SettingsCardRow(
                        title: "Waiting for you",
                        subtitle: UsageText.waitLine(summary),
                        showsDivider: !summary.topSessions.isEmpty
                    ) { EmptyView() }
                    ForEach(Array(summary.topSessions.enumerated()), id: \.offset) { index, row in
                        SettingsCardRow(
                            title: index == 0 ? "Top session by tokens" : "Next session",
                            subtitle: UsageText.sessionLine(row),
                            showsDivider: index < summary.topSessions.count - 1
                        ) { EmptyView() }
                    }
                }
                Text(UsageText.estimateLine(summary))
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard {
                SettingsCardRow(
                    title: "Export usage",
                    subtitle: model.exportNote ?? "Saves one file you choose, with a CSV beside it, to send to the Waggle team.",
                    showsDivider: true
                ) {
                    SettingsSecondaryButton(title: "Export usage…") { chooseExportFile() }
                        .disabled(model.isBusy)
                }
                SettingsCardRow(
                    title: "Delete usage data",
                    subtitle: "Removes every recorded tool call and usage count from this Mac.",
                    showsDivider: false
                ) {
                    SettingsSecondaryButton(title: "Delete usage data…") { showsDeleteConfirmation = true }
                        .disabled(model.isBusy)
                }
            }
        }
        .task { await model.start() }
        .alert("Delete usage data?", isPresented: $showsDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task { await model.deleteAll() } }
        } message: {
            Text("This removes every recorded tool call and usage count. Your decisions and answers are not touched.")
        }
    }

    private func chooseExportFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = UsageText.exportFileName()
        panel.canCreateDirectories = true
        panel.message = "Choose where to save your usage file. A CSV is saved beside it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.export(to: url) }
    }
}
