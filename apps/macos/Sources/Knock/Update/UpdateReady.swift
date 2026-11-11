import AppKit
import SwiftUI

/// "A new version is ready" (operator, 29 Sep: "work on an update toast,
/// bottom right, so they notice when the version is ready"; Pen "Update
/// toast", approved with "bottom right corner"). Knock downloads updates
/// silently and installs them on quit (Info.plist SUAutomaticallyUpdate),
/// so testers never noticed a new version. Sparkle calls
/// `UpdaterLogDelegate.updater(_:willInstallUpdateOnQuit:...)` once an update
/// is downloaded; that fills this model, and `UpdateToastView` shows it.
@MainActor
final class UpdateReadyModel: ObservableObject {
    static let shared = UpdateReadyModel()

    struct Ready: Equatable {
        let version: String
        /// The release notes' headline line ("**Your answer, always in
        /// view**"), or nil when the notes have none.
        let headline: String?
    }

    @Published private(set) var ready: Ready?
    /// "Later" or ×: hidden until the next launch. The update still installs
    /// when Knock quits.
    @Published private(set) var isDismissed = false
    private var installNow: (() -> Void)?
    /// Set by `UpdaterLogDelegate` so toast events land in update.log.
    var log: ((String) -> Void)?
    private var restartFileTimer: Timer?

    var isVisible: Bool { ready != nil && !isDismissed }
    /// The Updates page's status chip (HAIL-52): true once an update has
    /// downloaded and is waiting to install on quit, even after the toast
    /// itself has been dismissed - dismissing the toast never un-readies the
    /// update.
    var isReady: Bool { ready != nil }

    func present(_ ready: Ready, installNow: @escaping () -> Void) {
        self.ready = ready
        self.installNow = installNow
        isDismissed = false
        log?("toastPresented \(ready.version)")
        watchEvidenceRestartFile()
    }

    func restartNow() {
        // Which input pressed it (HAIL-80 follow-up: an install "on its own"):
        // the event type (1 mouse down, 2 mouse up, 10 key down) and whether
        // Knock was the active app.
        let event = NSApp.currentEvent
        log?("restartNowClicked event=\(event.map { String($0.type.rawValue) } ?? "none") key=\(event.flatMap { $0.type == .keyDown || $0.type == .keyUp ? $0.charactersIgnoringModifiers : nil } ?? "") active=\(NSApp.isActive)")
        UsageReporter.current?.record(.updateRestartClicked)
        installNow?()
    }

    /// Evidence and e2e only: `KNOCK_EVIDENCE_UPDATE_RESTART_FILE=<path>`
    /// "clicks" Restart now when that file appears (scripts/update-e2e.sh,
    /// toast mode). Never set in a release.
    private func watchEvidenceRestartFile(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard restartFileTimer == nil,
              let path = environment["KNOCK_EVIDENCE_UPDATE_RESTART_FILE"], !path.isEmpty else { return }
        restartFileTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard FileManager.default.fileExists(atPath: path) else { return }
            timer.invalidate()
            try? FileManager.default.removeItem(atPath: path)
            Task { @MainActor in
                self?.restartFileTimer = nil
                self?.restartNow()
            }
        }
    }

    func later() {
        isDismissed = true
    }

    /// "Check for Updates…" while an update is already waiting: un-hide the
    /// toast. Returns false when nothing is waiting, so the caller runs a
    /// normal Sparkle check instead.
    @discardableResult
    func showAgainIfReady() -> Bool {
        guard ready != nil else { return false }
        isDismissed = false
        return true
    }

    func openWhatsNew() {
        guard let ready else { return }
        UsageReporter.current?.record(.whatsNewOpened)
        NSWorkspace.shared.open(Self.releaseNotesURL(version: ready.version))
    }

    static func releaseNotesURL(version: String) -> URL {
        URL(string: "https://github.com/limone-eth/knock-releases/releases/tag/v\(version)")!
    }

    /// The first line that is bold on its own ("**Headline**") in the
    /// appcast's release notes (docs/release-notes/*.md), without the stars.
    /// Skips "**After updating:**"-style labels, which end in a colon.
    static func headline(fromReleaseNotes notes: String?) -> String? {
        guard let notes else { return nil }
        for raw in notes.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 else { continue }
            let inner = String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            if inner.isEmpty || inner.contains("**") || inner.hasSuffix(":") { continue }
            return inner
        }
        return nil
    }

    /// HAIL-192: what the toast says when agents wait on an open ask while Waggle restarts. A
    /// waiting agent keeps its connection through the restart and gets the answer after Waggle
    /// reopens. nil when no agent waits.
    static func restartWarning(waitingAgents: Int) -> String? {
        switch waitingAgents {
        case ..<1: return nil
        case 1: return "1 agent is waiting for your reply. Restarting is safe: it gets your answer after Waggle reopens."
        default: return "\(waitingAgents) agents are waiting for your reply. Restarting is safe: they get your answers after Waggle reopens."
        }
    }

    /// Evidence only: `KNOCK_EVIDENCE_UPDATE_TOAST=<version>` shows the toast
    /// with a no-op install, so it can be captured without a real update.
    func presentEvidenceIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let version = environment["KNOCK_EVIDENCE_UPDATE_TOAST"], !version.isEmpty else { return }
        present(Ready(version: version, headline: "Your answer, always in view"), installNow: {})
    }
}

/// The toast itself: bottom-right corner of the main window.
struct UpdateToastView: View {
    @ObservedObject var model: UpdateReadyModel
    /// Agents with an open ask right now (HAIL-192), counted by the caller.
    var waitingAgents: Int = 0

    var body: some View {
        if let ready = model.ready, model.isVisible {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.Colors.onFill)
                        .frame(width: 28, height: 28)
                        .background(Theme.Colors.accent)
                        .cornerRadius(7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Waggle \(ready.version) is ready")
                            .knockTextStyle(Theme.Typography.value13_5w600)
                            .foregroundColor(Theme.Colors.ink)
                        if let headline = ready.headline {
                            Text(headline)
                                .knockTextStyle(Theme.Typography.body12_5w400)
                                .foregroundColor(Theme.Colors.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    Button(action: model.later) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.Colors.ink3)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).pointerCursor()
                    .help("Hide until next time")
                }
                Text("Restart to update. Your decisions stay where they are.")
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                if let warning = UpdateReadyModel.restartWarning(waitingAgents: waitingAgents) {
                    Text(warning)
                        .knockTextStyle(Theme.Typography.body12_5w400)
                        .foregroundColor(Theme.Colors.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button(action: model.restartNow) {
                        Text("Restart now")
                            .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                            .foregroundColor(Theme.Colors.onFill)
                            .padding(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12))
                            .background(Theme.Colors.ink)
                            .cornerRadius(7)
                    }
                    .buttonStyle(.pressable).pointerCursor()
                    Button(action: model.later) {
                        Text("Later")
                            .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                            .foregroundColor(Theme.Colors.ink)
                            .padding(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.Colors.line2, lineWidth: 1))
                    }
                    .buttonStyle(.pressable).pointerCursor()
                    Spacer(minLength: 0)
                    Button(action: model.openWhatsNew) {
                        Text("What's new")
                            .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                            .foregroundColor(Theme.Colors.ink2)
                    }
                    .buttonStyle(.plain).pointerCursor()
                }
            }
            .padding(16)
            .frame(width: 360)
            .background(Theme.Colors.win)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Colors.line2, lineWidth: 1))
            .shadow(color: Theme.Colors.shadowBlack.opacity(0.15), radius: 14, x: 0, y: 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
