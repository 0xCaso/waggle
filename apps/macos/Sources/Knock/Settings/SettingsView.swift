import AppKit
import SwiftUI

/// The `⌘,` Settings window (KNOCK-17; sidebar redesign HAIL-50). A 210 pt
/// sidebar of six pages (Agents, Notifications, Previews, Updates, Data &
/// privacy, Help) and an 820x600 content area, showing only settings and
/// actions Knock already has - see the story's Contract for the full page
/// breakdown and its Non-goals for what stays out this release.
///
/// Light only (contract: "Non-goals: dark mode"): the window forces
/// `.preferredColorScheme(.light)`, like the onboarding window's own sheets
/// already do.
struct SettingsView: View {
    let client: KnockClient
    let askPreferences: AskPreferencesModel
    let onboardingModel: OnboardingModel

    @StateObject private var navigation = SettingsNavigationModel()

    var body: some View {
        VStack(spacing: 0) {
            TestCopyStripView()
            HStack(spacing: 0) {
                SettingsSidebarView(navigation: navigation)
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(width: 820, height: 600)
        }
        .frame(width: 820)
        .background(Theme.Colors.win)
        .preferredColorScheme(.light)
        .background(SettingsEvidenceShot())
        .onAppear { navigation.reportPage() }
        .task { await navigation.loadSharing { try await client.sharingGet() } }
    }

    @ViewBuilder
    private var page: some View {
        switch navigation.selected {
        case .agents:
            AgentsSettingsView(client: client)
        case .notifications:
            NotificationsSettingsView()
        case .screenshots:
            ScreenshotsSettingsView()
        case .artifacts:
            ArtifactsSettingsView(client: client)
        case .asks:
            AsksSettingsView(model: askPreferences, client: client)
        case .phone:
            PhoneSettingsView(client: client)
        case .sharing:
            SharingSettingsView(client: client)
        case .account:
            AccountSettingsView(client: client)
        case .updates:
            UpdatesSettingsView()
        case .data:
            DataPrivacySettingsView(client: client)
        case .help:
            HelpSettingsView(client: client, onboardingModel: onboardingModel)
        }
    }
}

/// Evidence only (HAIL-100): `KNOCK_EVIDENCE_SETTINGS_SHOT=<png path>[,<delay s>]`
/// draws the Settings window's own content view to a PNG with `cacheDisplay`,
/// once, a couple of seconds after it appears. It never reads the screen or
/// another app's windows, so it needs no Screen Recording permission.
private struct SettingsEvidenceShot: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        guard let raw = ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_SETTINGS_SHOT"], !raw.isEmpty else {
            return view
        }
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let path = parts.first, !path.isEmpty else { return view }
        let delay = parts.dropFirst().first.flatMap(Double.init) ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
            guard let content = view?.window?.contentView,
                  let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
            content.cacheDisplay(in: content.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
