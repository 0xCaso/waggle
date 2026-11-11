import SwiftUI

/// The words for the one place the app says its service is not reachable (audit batch, task 4). Pure, so a test
/// pins every state. No tool names and no internal words: the person sees "paused" and one button.
enum PausedCopy {
    enum Phase: Equatable {
        /// The service is not reachable and nothing is starting.
        case paused
        /// The person pressed the button and the app waits for the service.
        case starting
        /// The last start did not work.
        case startFailed
    }

    struct Card: Equatable {
        let title: String
        let line: String
        let button: String
        /// True while the button shows its working state and takes no press.
        let isWorking: Bool
    }

    static func card(_ phase: Phase) -> Card {
        switch phase {
        case .paused:
            Card(
                title: "Waggle is paused",
                line: "Agents can't reach you right now. Start Waggle to let them ask again.",
                button: "Start Waggle", isWorking: false)
        case .starting:
            Card(
                title: "Waggle is paused", line: "Starting Waggle. This takes a few seconds.",
                button: "Starting", isWorking: true)
        case .startFailed:
            Card(
                title: "Waggle is paused", line: "Waggle did not start. Try again.",
                button: "Try again", isWorking: false)
        }
    }

    /// The list footer while the service is not reachable.
    static func footer(_ phase: Phase) -> String {
        switch phase {
        case .paused, .startFailed: "Paused"
        case .starting: "Starting"
        }
    }

    /// The line next to the off Decide and Send controls on a saved request.
    static let answerLine = "Paused. Start Waggle to answer."
}

/// Holds the start of the service: which phase the card shows, and the one wait for the service to answer.
/// The launch and the reachability check come in as closures, so a test runs it with no real service.
@MainActor
final class ServiceStarter: ObservableObject {
    @Published private(set) var phase: PausedCopy.Phase = .paused

    private let launch: () -> Bool
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval

    init(
        launch: @escaping () -> Bool = { ServiceControl.launchDaemon() },
        timeout: TimeInterval = 15, pollInterval: TimeInterval = 0.2
    ) {
        self.launch = launch
        self.timeout = timeout
        self.pollInterval = pollInterval
    }

    /// Starts the service and waits, up to the deadline, until `isReachable` is true. A second press while it
    /// starts does nothing.
    func start(isReachable: @MainActor () -> Bool) async {
        guard phase != .starting else { return }
        phase = .starting
        guard launch() else {
            phase = .startFailed
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !isReachable() {
            if Date() >= deadline {
                phase = .startFailed
                return
            }
            try? await Task.sleep(for: .seconds(pollInterval))
        }
        phase = .paused
    }
}

/// The one card in the list column while the service is not reachable. White, a 1 pt line, the card radius:
/// no red.
struct PausedCardView: View {
    let phase: PausedCopy.Phase
    let onStart: () -> Void

    var body: some View {
        let card = PausedCopy.card(phase)
        VStack(alignment: .leading, spacing: 6) {
            Text(card.title)
                .knockTextStyle(Theme.Typography.cardTitle15w650)
                .foregroundColor(Theme.Colors.ink)
            Text(card.line)
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(Theme.Colors.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onStart) {
                HStack(spacing: 7) {
                    if card.isWorking {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                            .colorScheme(.dark)
                    }
                    Text(card.button).knockTextStyle(Theme.Typography.buttonSm12_5w500)
                }
                .foregroundColor(Theme.Colors.win)
                .padding(.vertical, 6)
                .padding(.horizontal, 11)
            }
            .buttonStyle(SettingsButtonStyle(kind: .primary))
            .disabled(card.isWorking)
            .padding(.top, 6)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.win)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.Colors.line, lineWidth: 1))
        .padding(EdgeInsets(top: 4, leading: 12, bottom: 8, trailing: 12))
        .accessibilityElement(children: .combine)
    }
}

private struct PausedAnswerLineKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// Set while the service is not reachable: the answer controls are off and this line says why.
    var pausedAnswerLine: String? {
        get { self[PausedAnswerLineKey.self] }
        set { self[PausedAnswerLineKey.self] = newValue }
    }
}
