import SwiftUI

/// Holds the Previews page's state: the self-check result comes from the
/// app-wide `IsolationGate` singleton (it compiles once and caches); the
/// toggle value comes from `HTMLPreviewSettings`. Carried over unchanged
/// from the pre-HAIL-50 `SettingsView`'s own model, minus the
/// notification-permission piece that now lives on its own page.
@MainActor
final class PreviewsSettingsModel: ObservableObject {
    @Published private(set) var isolationPassed = false
    @Published private(set) var htmlPreviewEnabled = false
    /// "Ask before opening links" (HAIL-52): on by default.
    @Published private(set) var linkConfirmEnabled = LinkConfirmSettings.isEnabled()

    func load() async {
        await IsolationGate.shared.runSelfCheckIfNeeded()
        isolationPassed = IsolationGate.shared.htmlPreviewAvailable
        htmlPreviewEnabled = HTMLPreviewSettings.isEnabled(isolationPassed: isolationPassed)
    }

    func setHTMLPreviewEnabled(_ enabled: Bool) {
        // Persist the explicit off/on; the effective value stays gated on the
        // self-check so a failed check can never be overridden on.
        HTMLPreviewSettings.setDisabled(!enabled)
        htmlPreviewEnabled = HTMLPreviewSettings.isEnabled(isolationPassed: isolationPassed)
    }

    func setLinkConfirmEnabled(_ enabled: Bool) {
        LinkConfirmSettings.setDisabled(!enabled)
        linkConfirmEnabled = LinkConfirmSettings.isEnabled()
    }
}

/// The Previews page (HAIL-50 contract): "the existing HTML preview toggle,
/// plus the isolation self-check result as a chip ('Check passed' / 'Check
/// failed, previews off') from `IsolationGate`." Plus "Ask before opening
/// links" (HAIL-52 contract), gating `MarkdownView`'s existing HAIL-33
/// confirm step.
struct PreviewsSettingsView: View {
    @StateObject private var model = PreviewsSettingsModel()

    var body: some View {
        SettingsPageChrome(title: SettingsPage.previews.title, subtitle: SettingsPage.previews.subtitle) {
            SettingsCard {
                SettingsCardRow(
                    title: "Show HTML previews",
                    subtitle: "Off shows the file name only; you can still open it full size.",
                    showsDivider: false
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { model.htmlPreviewEnabled },
                            set: { model.setHTMLPreviewEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch).pointerCursor()
                    .disabled(!model.isolationPassed)
                }
            }
            SettingsCard {
                SettingsCardRow(
                    title: "Ask before opening links",
                    subtitle: "Off opens a link from a write-up or prototype straight in your browser.",
                    showsDivider: false
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { model.linkConfirmEnabled },
                            set: { model.setLinkConfirmEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch).pointerCursor()
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                SettingsSectionLabel("SAFETY")
                SettingsCard {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 14))
                            .foregroundColor(model.isolationPassed ? Theme.Colors.ok : Theme.Colors.ink3)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Pages run in a locked sandbox")
                                .knockTextStyle(Theme.Typography.rowTitle13_5w600)
                                .foregroundColor(Theme.Colors.ink)
                            Text("No network, no access to your files or other apps. Checked every launch.")
                                .knockTextStyle(Theme.Typography.body12_5w400)
                                .foregroundColor(Theme.Colors.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        SettingsStatusChip(
                            text: model.isolationPassed ? "Check passed" : "Check failed, previews off",
                            ok: model.isolationPassed
                        )
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                }
            }
        }
        .task { await model.load() }
    }
}
