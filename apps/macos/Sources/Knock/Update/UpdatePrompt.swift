import AppKit
import SwiftUI

/// WAG-318: the update check on every start, and the prompt it opens.
///
/// The rules sit here, apart from Sparkle's types, so a test can drive them.
/// `Updater.runLaunchCheck` asks Sparkle for update information only (no
/// download, no window). `UpdaterLogDelegate` hands a found update to
/// `UpdatePromptModel`, and `UpdatePromptView` asks the person: Install and
/// restart, Later, or Skip this version.

/// "Check for updates when Waggle starts" (Settings, Updates). On by default.
enum LaunchUpdateCheckSettings {
    private static let key = "updateCheckOnStartDisabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(!enabled, forKey: key)
    }
}

/// "Skip this version": the one version the person never wants to hear about.
/// A newer version has another string, so it asks again.
enum SkippedUpdateVersion {
    private static let key = "updateSkippedVersion"

    static func current(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key)
    }

    static func skip(_ version: String, defaults: UserDefaults = .standard) {
        defaults.set(version, forKey: key)
    }

    static func isSkipped(_ version: String, defaults: UserDefaults = .standard) -> Bool {
        current(defaults: defaults) == version
    }
}

/// When the start check runs and when its result shows.
enum LaunchUpdateCheck {
    /// Once per start, never in a build without a feed key, never with the
    /// setting off. `scriptedCheck` is the e2e script, which owns the check.
    static func shouldRun(isAvailable: Bool, enabled: Bool, alreadyRan: Bool, scriptedCheck: Bool) -> Bool {
        isAvailable && enabled && !alreadyRan && !scriptedCheck
    }

    /// An update that is skipped, or already downloaded and waiting behind the
    /// restart toast, does not open the prompt.
    static func shouldPrompt(version: String, skipped: Bool, updateWaiting: Bool) -> Bool {
        !skipped && !updateWaiting
    }

    /// Up to three "What's new" lines from the appcast notes: the bullets
    /// (`- **Title.** More words`), each cut to its title, without the markers. Empty when the notes
    /// have no bullets.
    static func whatsNew(fromReleaseNotes notes: String?, limit: Int = 3) -> [String] {
        guard let notes else { return [] }
        var lines: [String] = []
        for raw in notes.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
            var body = String(line.dropFirst(2))
            // "**Title.** More words" keeps the title alone: one short line per change.
            if body.hasPrefix("**"), let end = body.dropFirst(2).range(of: "**") {
                body = String(body.dropFirst(2)[..<end.lowerBound])
            } else if let dot = body.firstIndex(of: "."), body.distance(from: body.startIndex, to: dot) < 110 {
                body = String(body[...dot])
            }
            let plain = body.replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces)
            if !plain.isEmpty { lines.append(plain) }
            if lines.count == limit { break }
        }
        return lines
    }
}

@MainActor
final class UpdatePromptModel: ObservableObject {
    static let shared = UpdatePromptModel()

    struct Offer: Equatable {
        let version: String
        let whatsNew: [String]
    }

    @Published private(set) var offer: Offer?
    /// "Install and restart" was pressed: the update downloads, then Waggle restarts.
    @Published private(set) var isInstalling = false
    /// Starts the download and the restart (`Updater.requestInstall`).
    var startInstall: () -> Void = {}
    var log: (String) -> Void = { _ in }

    func present(_ offer: Offer) {
        guard self.offer == nil else { return }
        self.offer = offer
        isInstalling = false
        log("updatePromptShown \(offer.version)")
        UsageReporter.current?.record(.updatePromptShown)
    }

    func install() {
        guard offer != nil, !isInstalling else { return }
        isInstalling = true
        log("updatePromptInstall")
        UsageReporter.current?.record(.updateInstallClicked)
        startInstall()
    }

    /// Later: nothing is stored, so the next start asks again.
    func later() {
        guard !isInstalling else { return }
        log("updatePromptLater")
        UsageReporter.current?.record(.updateLaterClicked)
        offer = nil
        UpdateReadyModel.shared.later()
    }

    func skip(defaults: UserDefaults = .standard) {
        guard let offer, !isInstalling else { return }
        SkippedUpdateVersion.skip(offer.version, defaults: defaults)
        log("updatePromptSkip \(offer.version)")
        UsageReporter.current?.record(.updateSkipped)
        self.offer = nil
        UpdateReadyModel.shared.later()
    }

    /// The download failed after Install: close the prompt, the next start asks again.
    func installFailed() {
        guard isInstalling else { return }
        isInstalling = false
        offer = nil
    }

    /// Evidence only: `KNOCK_EVIDENCE_UPDATE_PROMPT=<version>` shows the prompt
    /// with sample notes and a no-op install.
    func presentEvidenceIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let version = environment["KNOCK_EVIDENCE_UPDATE_PROMPT"], !version.isEmpty else { return }
        startInstall = {}
        present(Offer(version: version, whatsNew: [
            "Comment right on the decision. You can now pin comments straight from the decision page.",
            "Tidier option rows. In a tight row the Recommended pill shrinks.",
        ]))
    }
}

struct UpdatePromptView: View {
    @ObservedObject var model: UpdatePromptModel

    var body: some View {
        if let offer = model.offer {
            ZStack {
                Color.black.opacity(0.18).ignoresSafeArea()
                card(offer)
            }
            .transition(.opacity)
        }
    }

    private func card(_ offer: UpdatePromptModel.Offer) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.Colors.onFill)
                    .frame(width: 28, height: 28)
                    .background(Theme.Colors.accent)
                    .cornerRadius(7)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Waggle \(offer.version) is out")
                        .knockTextStyle(Theme.Typography.value13_5w600)
                        .foregroundColor(Theme.Colors.ink)
                    Text("You have Waggle \(Updater.appVersion).")
                        .knockTextStyle(Theme.Typography.body12_5w400)
                        .foregroundColor(Theme.Colors.ink3)
                }
            }
            if !offer.whatsNew.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What's new")
                        .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                        .foregroundColor(Theme.Colors.ink)
                    ForEach(offer.whatsNew, id: \.self) { line in
                        Text(line)
                            .knockTextStyle(Theme.Typography.body12_5w400)
                            .foregroundColor(Theme.Colors.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text(model.isInstalling
                 ? "Downloading. Waggle restarts when it is ready."
                 : "Waggle restarts to install. Your decisions stay where they are.")
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(Theme.Colors.ink3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(action: model.install) {
                    Text(model.isInstalling ? "Downloading…" : "Install and restart")
                        .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                        .foregroundColor(Theme.Colors.onFill)
                        .padding(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12))
                        .background(Theme.Colors.ink.opacity(model.isInstalling ? 0.6 : 1))
                        .cornerRadius(7)
                }
                .buttonStyle(.pressable).pointerCursor()
                .disabled(model.isInstalling)
                Button(action: model.later) {
                    Text("Later")
                        .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                        .foregroundColor(Theme.Colors.ink)
                        .padding(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.Colors.line2, lineWidth: 1))
                }
                .buttonStyle(.pressable).pointerCursor()
                .disabled(model.isInstalling)
                Spacer(minLength: 0)
                Button(action: { model.skip() }) {
                    Text("Skip this version")
                        .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                        .foregroundColor(Theme.Colors.ink2)
                }
                .buttonStyle(.plain).pointerCursor()
                .disabled(model.isInstalling)
            }
        }
        .padding(18)
        .frame(width: 400)
        .background(Theme.Colors.win)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Colors.line2, lineWidth: 1))
        .shadow(color: Theme.Colors.shadowBlack.opacity(0.15), radius: 14, x: 0, y: 8)
    }
}
