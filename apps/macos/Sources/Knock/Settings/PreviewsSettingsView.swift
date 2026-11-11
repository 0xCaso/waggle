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

/// The "Previews" section of the Artifacts page (it was its own page, HAIL-50): "the existing HTML preview
/// toggle, plus the isolation self-check result", and "Ask before opening links" (HAIL-52). The sandbox
/// sentence is the first switch's subtitle, and the check chip shows only when the check failed.
struct PreviewsSection: View {
    @StateObject private var model = PreviewsSettingsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionLabel("PREVIEWS")
            SettingsCard {
                SettingsCardRow(
                    title: "Show HTML previews",
                    subtitle: "Off shows the file name only; you can still open it full size. Pages run in a locked sandbox with no network and no access to your files."
                ) {
                    HStack(spacing: 10) {
                        if !model.isolationPassed {
                            SettingsStatusChip(text: "Check failed, previews off", ok: false)
                        }
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
                        .accessibilityLabel("Show HTML previews")
                    }
                }
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
                    .accessibilityLabel("Ask before opening links")
                }
            }
        }
        .task { await model.load() }
    }
}
