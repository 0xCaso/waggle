import SwiftUI

/// The Sharing page (WAG-387): one switch. Off by default. With it off, Waggle makes no call to the sharing service.
@MainActor
final class SharingSettingsModel: ObservableObject {
    @Published private(set) var state: SharingState = .off
    @Published var problem: String?
    /// False until the daemon has answered once. The switch waits for it, so it never shows a guess.
    @Published private(set) var loaded = false
    @Published private(set) var isBusy = false
    private let fetch: () async throws -> SharingState
    private let setCall: (Bool) async throws -> SharingState
    private let retryInterval: Duration

    init(client: KnockClient, retryInterval: Duration = .seconds(1)) {
        fetch = { try await client.sharingGet() }
        setCall = { try await client.sharingSetEnabled($0) }
        self.retryInterval = retryInterval
    }

    /// For tests: the daemon calls come from closures.
    init(fetch: @escaping () async throws -> SharingState, set: @escaping (Bool) async throws -> SharingState = { _ in .off }, retryInterval: Duration = .milliseconds(10)) {
        self.fetch = fetch
        setCall = set
        self.retryInterval = retryInterval
    }

    @discardableResult
    func load() async -> Bool {
        guard let s = try? await fetch() else { return false }
        state = s
        loaded = true
        return true
    }

    /// Settings can open before the daemon is up (it starts on demand): ask again until it answers.
    func loadUntilReady() async {
        while !Task.isCancelled {
            if await load() { return }
            try? await Task.sleep(for: retryInterval)
        }
    }

    func setEnabled(_ on: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        problem = nil
        do {
            state = try await setCall(on)
        } catch {
            problem = PhoneSettingsModel.words(for: error)
            await load()
        }
    }
}

struct SharingSettingsView: View {
    @StateObject private var model: SharingSettingsModel

    init(client: KnockClient) {
        _model = StateObject(wrappedValue: SharingSettingsModel(client: client))
    }

    var body: some View {
        SettingsPageChrome(title: SettingsPage.sharing.title, subtitle: SettingsPage.sharing.subtitle) {
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionLabel("SHARING")
                SettingsCard {
                    SettingsCardRow(
                        title: "Sharing",
                        subtitle: "Adds a Share button to each case. Waggle then talks to one service, app.waggle.so, only for a case you share.",
                        showsDivider: false
                    ) {
                        Toggle("", isOn: Binding(get: { model.state.enabled }, set: { on in Task { await model.setEnabled(on) } }))
                            .labelsHidden()
                            .toggleStyle(.switch).pointerCursor()
                            .disabled(!model.loaded || model.isBusy)
                    }
                }
                if let problem = model.problem {
                    Text(problem)
                        .knockTextStyle(Theme.Typography.body12_5w400)
                        .foregroundColor(Theme.Colors.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(!model.loaded ? "Checking the Waggle service..." : model.state.sharedCount > 0
                    ? "\(model.state.sharedCount) shared. Stop sharing a case from its Share button before you turn this off."
                    : "Your sharing key for a case stays in the Keychain on this Mac.")
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await model.loadUntilReady() }
        .onReceive(NotificationCenter.default.publisher(for: .knockSharingChanged)) { _ in Task { await model.load() } }
    }
}
