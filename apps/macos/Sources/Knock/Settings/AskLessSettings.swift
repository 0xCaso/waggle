import SwiftUI

/// The words of the "Small things" card on Requests (WAG-412, was the Ask less page). Plain, friendly, no em-dashes.
enum AskLessCopy {
    static let masterTitle = "Let the agent decide small things"
    static let masterBody = "When an agent asks a small question and has a recommendation, Waggle answers with it at once. You see every answer in a folded list in the queue, and you can change your mind."
    static let label = "SMALL THINGS"
    static let footer = "Reviews and asks with no recommendation always come to you. Agents only use this for choices that are easy to undo."
    static let footerOff = "Agents learn about this the next time they read Waggle's guide."
}

/// Holds the page's switches. The daemon owns the value (only it writes knock.db), so a flip is sent over
/// `settings.set`; a failed send puts the old value back. Turning the master off turns every rule off.
@MainActor
final class AskLessSettingsModel: ObservableObject {
    @Published private(set) var value: AskLess = .off
    @Published private(set) var loaded = false
    @Published private(set) var problem: String?

    private let client: KnockClient
    private let retryDelay: Duration
    private let maxAttempts: Int
    /// Called after a change, so the queue starts or stops asking for the folded list.
    var onChange: ((AskLess) -> Void)?

    init(client: KnockClient, retryDelay: Duration = .milliseconds(500), maxAttempts: Int = 20) {
        self.client = client
        self.retryDelay = retryDelay
        self.maxAttempts = maxAttempts
    }

    func load() async {
        for attempt in 0..<maxAttempts {
            if let stored = try? await client.askLess() {
                value = stored
                loaded = true
                return
            }
            if attempt < maxAttempts - 1 { try? await Task.sleep(for: retryDelay) }
        }
    }

    func isOn(_ category: AskCategory) -> Bool { value.isOn(category) }

    /// The category switches are off and not clickable while the master is off.
    var rulesEnabled: Bool { loaded && value.enabled }

    func setMaster(_ on: Bool) async {
        await send(on ? AskLess(enabled: true, rules: value.rules) : .off)
    }

    func set(_ category: AskCategory, _ on: Bool) async {
        guard value.enabled else { return }
        await send(value.setting(category, to: on))
    }

    private func send(_ next: AskLess) async {
        guard next != value else { return }
        let previous = value
        value = next
        problem = nil
        do {
            value = try await client.setAskLess(next)
            onChange?(value)
        } catch {
            value = previous
            problem = "Waggle could not save this. Try again."
        }
    }
}

/// The "Small things" card on the Requests page: one master switch, then one switch per category. It was
/// the Ask less page (WAG-412); the keys and values it reads and writes did not change.
struct AskLessSection: View {
    @StateObject private var model: AskLessSettingsModel

    init(client: KnockClient) {
        let model = AskLessSettingsModel(client: client)
        model.onChange = { value in
            NotificationCenter.default.post(name: .knockAskLessChanged, object: value.enabled)
        }
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionLabel(AskLessCopy.label)
            SettingsCard {
                SettingsCardRow(title: AskLessCopy.masterTitle, subtitle: AskLessCopy.masterBody) {
                    Toggle("", isOn: Binding(get: { model.value.enabled }, set: { on in Task { await model.setMaster(on) } }))
                        .labelsHidden()
                        .toggleStyle(.switch).pointerCursor()
                        .disabled(!model.loaded)
                        .accessibilityLabel(AskLessCopy.masterTitle)
                }
                ForEach(Array(AskCategory.allCases.enumerated()), id: \.element.id) { index, category in
                    SettingsCardRow(
                        title: category.title, subtitle: category.detail,
                        showsDivider: index < AskCategory.allCases.count - 1
                    ) {
                        Toggle("", isOn: Binding(get: { model.isOn(category) }, set: { on in Task { await model.set(category, on) } }))
                            .labelsHidden()
                            .toggleStyle(.switch).pointerCursor()
                            .disabled(!model.rulesEnabled)
                            .accessibilityLabel(category.title)
                    }
                    .opacity(model.rulesEnabled ? 1 : 0.55)
                }
            }
            if let problem = model.problem {
                Text(problem)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.accent)
            }
            Text(AskLessCopy.footer)
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(Theme.Colors.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await model.load() }
    }
}

extension Notification.Name {
    /// Posted by the Ask less page with the new master value, so the queue starts or stops showing "Decided for you".
    static let knockAskLessChanged = Notification.Name("knockAskLessChanged")
}
