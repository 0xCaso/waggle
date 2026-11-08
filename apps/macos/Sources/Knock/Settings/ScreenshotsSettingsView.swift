import SwiftUI

/// Settings › Screenshots (WAG-402). Off by default. With Off, Waggle runs no screenshot watch at all.
@MainActor
final class ScreenshotsSettingsModel: ObservableObject {
    @Published private(set) var mode: ScreenshotMode
    @Published private(set) var snipOn: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = ScreenshotSettings.mode(defaults: defaults)
        snipOn = ScreenshotSettings.snipIsOn(defaults: defaults)
    }

    func setSnip(_ on: Bool) {
        ScreenshotSettings.setSnip(on, defaults: defaults)
        snipOn = on
    }

    func setMode(_ mode: ScreenshotMode) {
        ScreenshotSettings.setMode(mode, defaults: defaults)
        self.mode = mode
    }
}

struct ScreenshotsSettingsView: View {
    @StateObject private var model = ScreenshotsSettingsModel()

    var body: some View {
        SettingsPageChrome(title: SettingsPage.screenshots.title, subtitle: SettingsPage.screenshots.subtitle) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ScreenshotCopy.settingsTitle)
                        .knockTextStyle(Theme.Typography.value13_5w600)
                        .foregroundColor(Theme.Colors.ink)
                    Text(ScreenshotCopy.settingsSub)
                        .knockTextStyle(Theme.Typography.caption11_5w400)
                        .foregroundColor(Theme.Colors.ink3)
                }
                SettingsCard {
                    ForEach(Array(ScreenshotMode.allCases.enumerated()), id: \.element) { index, mode in
                        choice(mode, showsDivider: index < ScreenshotMode.allCases.count - 1)
                    }
                }
                if model.mode == .everyShot {
                    // macOS keeps the file hidden while its thumbnail shows, so the badge waits for it (WAG-403).
                    Text(ScreenshotCopy.thumbnailTip)
                        .knockTextStyle(Theme.Typography.caption11_5w400)
                        .foregroundColor(Theme.Colors.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                snipSection
            }
        }
    }

    /// WAG-404: the second section. Off by default.
    private var snipSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ScreenshotCopy.snipTitle)
                    .knockTextStyle(Theme.Typography.value13_5w600)
                    .foregroundColor(Theme.Colors.ink)
                Text(ScreenshotCopy.snipSub)
                    .knockTextStyle(Theme.Typography.caption11_5w400)
                    .foregroundColor(Theme.Colors.ink3)
            }
            SettingsCard {
                snipChoice(on: false, title: "Off", subtitle: nil, showsDivider: true)
                snipChoice(on: true, title: "On", subtitle: ScreenshotCopy.snipOnSub, showsDivider: false)
            }
        }
        .padding(.top, 8)
    }

    private func snipChoice(on: Bool, title: String, subtitle: String?, showsDivider: Bool) -> some View {
        let selected = model.snipOn == on
        return Button { model.setSnip(on) } label: {
            SettingsCardRow(title: title, subtitle: subtitle, showsDivider: showsDivider) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundColor(selected ? Theme.Colors.honey600 : Theme.Colors.line2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func choice(_ mode: ScreenshotMode, showsDivider: Bool) -> some View {
        let selected = model.mode == mode
        return Button { model.setMode(mode) } label: {
            SettingsCardRow(title: mode.title, subtitle: mode.subtitle, showsDivider: showsDivider) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundColor(selected ? Theme.Colors.honey600 : Theme.Colors.line2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
