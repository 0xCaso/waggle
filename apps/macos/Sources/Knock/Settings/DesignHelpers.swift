import Foundation
import SwiftUI

/// HAIL-239: the optional "Design helpers" card in Settings › Agents. It adds or removes the
/// Impeccable plugin (Apache 2.0) in Claude Code with `waggle design-helpers add|remove`, only on a
/// click. The daemon runs the `claude plugin` commands; the claude CLI does the download.
enum DesignHelpersCopy {
    static let title = "Design helpers"
    static let body = "Impeccable helps your agents shape, critique and polish prototypes. Free, open source (Apache 2.0)."
    static let add = "Add to Claude Code"
    static let remove = "Remove"
    static let installing = "Adding"
    static let removing = "Removing"
    static let addFailed = "Could not add Impeccable. Check that Claude Code is up to date and online, then try again."
    static let removeFailed = "Could not remove Impeccable. Try again."
}

enum DesignHelpersCommand {
    static let status = ["design-helpers", "status"]
    static let add = ["design-helpers", "add"]
    static let remove = ["design-helpers", "remove"]
}

@MainActor
final class DesignHelpersModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case installing
        case removing
        case failed(String)
    }

    @Published private(set) var isInstalled = false
    @Published private(set) var phase: Phase = .idle
    /// False until the status probe works: the card stays hidden for a Mac with no Claude Code
    /// plugin support, so the feature never gets in the way.
    @Published private(set) var isAvailable = false

    private let runner: OnboardingCommandRunning

    init(runner: OnboardingCommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    var isWorking: Bool { phase == .installing || phase == .removing }

    /// Reads `claude plugin list` through the daemon. Never installs anything.
    func refresh() async {
        var lines: [String] = []
        let code = await runner.run(DesignHelpersCommand.status, onLine: { lines.append($0) })
        guard code == 0 else {
            isAvailable = false
            return
        }
        isAvailable = true
        isInstalled = lines.contains { $0.trimmingCharacters(in: .whitespaces) == "installed" }
    }

    /// "Add to Claude Code" and "Remove": run the command, then check what Claude Code shows.
    func set(installed wanted: Bool) async {
        guard !isWorking else { return }
        phase = wanted ? .installing : .removing
        let code = await runner.run(wanted ? DesignHelpersCommand.add : DesignHelpersCommand.remove, onLine: { _ in })
        await refresh()
        if code == 0, isInstalled == wanted {
            phase = .idle
        } else {
            phase = .failed(wanted ? DesignHelpersCopy.addFailed : DesignHelpersCopy.removeFailed)
        }
    }
}

struct DesignHelpersCard: View {
    @ObservedObject var model: DesignHelpersModel

    var body: some View {
        if model.isAvailable {
            SettingsCard {
                SettingsCardRow(title: DesignHelpersCopy.title, subtitle: DesignHelpersCopy.body, showsDivider: false) {
                    HStack(spacing: 10) {
                        switch model.phase {
                        case .installing: LoadingStatus(label: DesignHelpersCopy.installing)
                        case .removing: LoadingStatus(label: DesignHelpersCopy.removing)
                        case .idle, .failed: EmptyView()
                        }
                        if model.isInstalled {
                            SettingsSecondaryButton(title: DesignHelpersCopy.remove) {
                                Task { await model.set(installed: false) }
                            }
                            .disabled(model.isWorking)
                        } else {
                            SettingsPrimaryButton(title: DesignHelpersCopy.add) {
                                Task { await model.set(installed: true) }
                            }
                            .disabled(model.isWorking)
                        }
                    }
                }
                if case .failed(let message) = model.phase {
                    Text(message)
                        .knockTextStyle(Theme.Typography.body12_5w400)
                        .foregroundColor(Theme.Colors.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
