import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Copy and limits for the Design kit block on Settings > Artifacts (HAIL-166).
enum DesignKitCopy {
    /// What the daemon stores. Agents get only the first `agentDesignSystemBytes`.
    static let maxDesignSystemBytes = 1024 * 1024
    static let agentDesignSystemBytes = 8 * 1024
    static let maxToneBytes = 1024
    static let designSystemNote = "Paste or upload. Agents get the first 8 KB; Expand shows it all."
    static let cardNote = "Every agent gets this kit, unless its project has its own .knock/design-kit.md. Leave a field empty to skip it."
    static let projectTitle = "Set up a design kit in a project"
    static let projectPrompt = "Make a design kit for this project in .knock/design-kit.md. Ask me in Waggle for the design system, the Pen file and the tone."
}

/// Holds the Design kit block's drafts. The daemon owns the kit (only it writes knock.db): every
/// save goes over `design_kit.set`, and Undo over `design_kit.undo`. The app never reads or writes a
/// project's files; an upload reads only the one file the person picks.
@MainActor
final class DesignKitModel: ObservableObject {
    @Published var designSystem = ""
    @Published var penFile = ""
    @Published var tone = ""
    @Published private(set) var enabled = false
    @Published private(set) var kit = DesignKit.empty
    @Published private(set) var canUndo = false
    @Published private(set) var uploadedFile: (name: String, bytes: Int)?
    @Published private(set) var message: String?

    private let client: KnockClient
    private let retryDelay: Duration
    private let maxAttempts: Int
    private var saveTask: Task<Void, Never>?

    init(client: KnockClient, retryDelay: Duration = .milliseconds(500), maxAttempts: Int = 20) {
        self.client = client
        self.retryDelay = retryDelay
        self.maxAttempts = maxAttempts
    }

    /// The socket may still be connecting when the page first appears, so a failed read is retried.
    func load() async {
        for attempt in 0..<maxAttempts {
            if let result = try? await client.designKit() {
                adopt(result, replaceDrafts: true)
                return
            }
            if attempt < maxAttempts - 1 { try? await Task.sleep(for: retryDelay) }
        }
    }

    private func adopt(_ result: DesignKitResult, replaceDrafts: Bool) {
        kit = result.kit
        canUndo = result.canUndo
        enabled = result.kit.enabled
        if replaceDrafts {
            designSystem = result.kit.designSystem
            penFile = result.kit.penFile
            tone = result.kit.tone
        }
    }

    /// The fields whose draft differs from the stored kit.
    var pendingChange: DesignKitChange {
        DesignKitChange(
            designSystem: designSystem != kit.designSystem ? designSystem : nil,
            penFile: penFile != kit.penFile ? penFile : nil,
            tone: tone != kit.tone ? tone : nil,
            enabled: nil)
    }

    /// Typing saves after a short pause, so each keystroke is not a version.
    func scheduleSave(after delay: Duration = .milliseconds(800)) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    func save() async {
        saveTask?.cancel()
        let change = pendingChange
        guard !change.isEmpty else { return }
        if let problem = Self.problem(with: change) {
            message = problem
            return
        }
        await send(change)
    }

    func setEnabled(_ on: Bool) async {
        guard on != enabled else { return }
        await save()
        await send(DesignKitChange(enabled: on))
    }

    private func send(_ change: DesignKitChange) async {
        do {
            let result = try await client.setDesignKit(change)
            adopt(result, replaceDrafts: false)
            message = nil
        } catch {
            message = "Could not save the design kit. Try again in a moment."
        }
    }

    func undo() async {
        saveTask?.cancel()
        do {
            adopt(try await client.undoDesignKit(), replaceDrafts: true)
            message = nil
        } catch {
            message = "Could not undo that change."
        }
    }

    /// Reads one file the person picked into the design system text. Nothing else is read.
    func upload(from url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            message = "Could not read that file."
            return
        }
        guard let text = String(data: data, encoding: .utf8) else {
            message = "That file is not text. Pick a .md, .markdown or .txt file."
            return
        }
        guard data.count <= DesignKitCopy.maxDesignSystemBytes else {
            message = "That file is \(Self.sizeLabel(data.count)). The limit is 1 MB, so pick a shorter one."
            return
        }
        designSystem = text
        uploadedFile = (url.lastPathComponent, data.count)
        message = nil
        scheduleSave(after: .zero)
    }

    func choosePenFile(_ url: URL) {
        penFile = url.path
        scheduleSave(after: .zero)
    }

    /// A limit the daemon would refuse, said in plain words before the call.
    static func problem(with change: DesignKitChange) -> String? {
        if let text = change.designSystem, text.utf8.count > DesignKitCopy.maxDesignSystemBytes {
            return "The design system is \(sizeLabel(text.utf8.count)). The limit is 1 MB, so shorten it."
        }
        if let text = change.tone, text.utf8.count > DesignKitCopy.maxToneBytes {
            return "The tone is too long. Keep it to a line or two."
        }
        if let path = change.penFile, !path.isEmpty, !path.hasPrefix("/") || path.contains("\n") {
            return "The Pen file needs a full path that starts with /. Use Choose… to pick it."
        }
        return nil
    }

    static func sizeLabel(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    /// "<size> · agents get the first 8 KB", only when the text is over 8 KB.
    static func overCapLine(bytes: Int) -> String? {
        bytes > DesignKitCopy.agentDesignSystemBytes ? "\(sizeLabel(bytes)) · agents get the first 8 KB" : nil
    }

    /// "Changed by Claude · 2 minutes ago", only when the last change came from an agent.
    func changedByLine(now: Date = Date()) -> String? {
        Self.changedByLine(kit: kit, now: now)
    }

    static func changedByLine(kit: DesignKit, now: Date) -> String? {
        guard let by = kit.updatedBy, by != "you", !by.isEmpty else { return nil }
        let runtime = by.split(separator: ":").first.map(String.init) ?? by
        let name = runtime.prefix(1).uppercased() + runtime.dropFirst()
        guard let stamp = kit.updatedAt, let date = parse(stamp) else { return "Changed by \(name)" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Changed by \(name) · \(formatter.localizedString(for: date, relativeTo: now))"
    }

    private static func parse(_ stamp: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: stamp) { return date }
        return ISO8601DateFormatter().date(from: stamp)
    }
}

/// The Design kit block (HAIL-166, knock.pen "Settings window v2"): an On/Off switch, a card of
/// three rows (Design system, Pen file, Tone of copy), and a "For one project" row with Copy.
struct DesignKitSection: View {
    @StateObject private var model: DesignKitModel
    @State private var showsFullText = false

    init(client: KnockClient) {
        _model = StateObject(wrappedValue: DesignKitModel(client: client))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SettingsSectionLabel("DESIGN KIT")
                    Spacer(minLength: 12)
                    Text(model.kit.enabled ? "On" : "Off")
                        .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                        .foregroundColor(Theme.Colors.ink2)
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { model.kit.enabled },
                            set: { on in Task { await model.setEnabled(on) } }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch).pointerCursor()
                    .accessibilityLabel("Design kit")
                }
                SettingsCard {
                    kitRow(title: "Design system", hint: "Your design.md, pasted or uploaded", showsDivider: true) { designSystemValue }
                    kitRow(title: "Pen file", hint: "Agents design in it, with its components", showsDivider: true) { penFileValue }
                    kitRow(title: "Tone of copy", hint: "How text should sound", showsDivider: false) { toneValue }
                }
                Text(DesignKitCopy.cardNote)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = model.message {
                    Text(message)
                        .knockTextStyle(Theme.Typography.reviewNoteText12w400)
                        .foregroundColor(Theme.Colors.accent)
                }
                changedByRow
            }
            VStack(alignment: .leading, spacing: 10) {
                SettingsSectionLabel("FOR ONE PROJECT")
                SettingsCard {
                    SettingsCardRow(
                        title: DesignKitCopy.projectTitle,
                        subtitle: DesignKitCopy.projectPrompt,
                        showsDivider: false
                    ) {
                        SettingsCopyButton(text: DesignKitCopy.projectPrompt)
                    }
                }
            }
        }
        .task { await model.load() }
        .onChange(of: model.designSystem) { _, _ in model.scheduleSave() }
        .onChange(of: model.penFile) { _, _ in model.scheduleSave() }
        .onChange(of: model.tone) { _, _ in model.scheduleSave() }
        .sheet(isPresented: $showsFullText) { fullTextSheet }
    }

    @ViewBuilder
    private var changedByRow: some View {
        if let line = model.changedByLine() {
            HStack(spacing: 8) {
                Text(line)
                    .knockTextStyle(Theme.Typography.reviewNoteText12w400)
                    .foregroundColor(Theme.Colors.ink3)
                if model.canUndo {
                    Button(action: { Task { await model.undo() } }) {
                        Text("Undo")
                            .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                            .foregroundColor(Theme.Colors.accent)
                    }
                    .buttonStyle(.plain).pointerCursor()
                }
            }
        }
    }

    private func kitRow<Value: View>(
        title: String, hint: String, showsDivider: Bool, @ViewBuilder value: () -> Value
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .knockTextStyle(Theme.Typography.titlebarTitle13w600)
                        .foregroundColor(Theme.Colors.ink)
                    Text(hint)
                        .knockTextStyle(Theme.Typography.caption11_5w400)
                        .foregroundColor(Theme.Colors.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 150, alignment: .leading)
                value().frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            if showsDivider {
                Rectangle().fill(Theme.Colors.line).frame(height: 1)
            }
        }
    }

    private var designSystemValue: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SettingsSecondaryButton(icon: "arrow.up.doc", title: "Upload .md…", action: pickMarkdown)
                if let file = model.uploadedFile {
                    Text("\(file.name) · \(DesignKitModel.sizeLabel(file.bytes))")
                        .knockTextStyle(Theme.Typography.monoMeta11_5w400)
                        .foregroundColor(Theme.Colors.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button(action: { showsFullText = true }) {
                    Text("Expand")
                        .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                        .foregroundColor(Theme.Colors.accent)
                }
                .buttonStyle(.plain).pointerCursor()
            }
            textArea(height: 170)
            Text(DesignKitCopy.designSystemNote)
                .knockTextStyle(Theme.Typography.caption11_5w400)
                .foregroundColor(Theme.Colors.ink3)
                .fixedSize(horizontal: false, vertical: true)
            if let line = DesignKitModel.overCapLine(bytes: model.designSystem.utf8.count) {
                Text(line)
                    .font(.system(size: 11.5))
                    .foregroundColor(Theme.Colors.ink3)
            }
        }
    }

    private func textArea(height: CGFloat?) -> some View {
        TextEditor(text: $model.designSystem)
            .font(Theme.Typography.monoMeta11_5w400.font)
            .foregroundColor(Theme.Colors.ink)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: height)
            .frame(maxHeight: height == nil ? .infinity : nil)
            .background(Theme.Colors.list)
            .cornerRadius(7)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.Colors.line, lineWidth: 1))
            .accessibilityLabel("Design system")
    }

    private var penFileValue: some View {
        HStack(spacing: 10) {
            TextField("/path/to/design.pen", text: $model.penFile)
                .textFieldStyle(.plain)
                .font(Theme.Typography.monoMeta11_5w400.font)
                .foregroundColor(Theme.Colors.ink)
                .padding(.vertical, 7)
                .padding(.horizontal, 9)
                .background(Theme.Colors.list)
                .cornerRadius(7)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.Colors.line, lineWidth: 1))
                .accessibilityLabel("Pen file path")
            SettingsSecondaryButton(title: "Choose…", action: pickPenFile)
        }
    }

    private var toneValue: some View {
        TextField("Plain and warm. No jargon.", text: $model.tone, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(2, reservesSpace: true)
            .knockTextStyle(Theme.Typography.body13w400)
            .foregroundColor(Theme.Colors.ink)
            .padding(.vertical, 7)
            .padding(.horizontal, 9)
            .background(Theme.Colors.list)
            .cornerRadius(7)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.Colors.line, lineWidth: 1))
            .accessibilityLabel("Tone of copy")
    }

    private var fullTextSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Design system")
                .knockTextStyle(Theme.Typography.dialogTitle19w650)
                .foregroundColor(Theme.Colors.ink)
            textArea(height: nil)
            HStack {
                Text(DesignKitModel.overCapLine(bytes: model.designSystem.utf8.count) ?? DesignKitModel.sizeLabel(model.designSystem.utf8.count))
                    .knockTextStyle(Theme.Typography.monoMeta11_5w400)
                    .foregroundColor(Theme.Colors.ink3)
                Spacer()
                SettingsPrimaryButton(title: "Done") {
                    showsFullText = false
                    Task { await model.save() }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 480)
        .background(Theme.Colors.win)
    }

    private func pickMarkdown() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["md", "markdown", "txt"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url { model.upload(from: url) }
    }

    private func pickPenFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["pen"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url { model.choosePenFile(url) }
    }
}
