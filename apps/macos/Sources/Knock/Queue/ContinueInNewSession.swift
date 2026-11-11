import Foundation
import SwiftUI

/// WAG-410: the agent session of a case ended. "Continue in a new session" starts a new one with the
/// question, the options and the operator's answer, through the same launcher as Start from a document.
/// It runs only on the operator's click.
enum ContinueInNewSessionCopy {
    static let label = "Continue in a new session"
    static let starting = "Starting a new session..."
    static let started = "A new session is starting. Your answer is in its first message."
    static let noFolder = "Waggle does not know the folder of the old session. Copy the answer and paste it where you work."
    static let failedPrefix = "The new session did not start. "
}

enum ContinuePrompt {
    /// The first message of the new session. The question, the options, then the answer (or a line that
    /// says there is none yet). `answer` is what the operator chose or typed; `nil` falls back to the
    /// answer already sent for this case.
    static func build(for item: Case, answer: String?) -> String {
        var parts: [String] = []
        parts.append("An earlier session of this task closed before it read my answer in Waggle (case \(item.id)). Continue from here.")
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { parts.append("Question:\n\(title)") }
        let need = item.need.trimmingCharacters(in: .whitespacesAndNewlines)
        if !need.isEmpty, need != title { parts.append("What you needed:\n\(need)") }
        if !item.options.isEmpty {
            let lines = item.options.map { "- \($0.displayTitle): \($0.label)" }
            parts.append("Options:\n" + lines.joined(separator: "\n"))
        }
        let given = answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sent = item.latestReplyAnswerText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !given.isEmpty {
            parts.append("My answer:\n\(given)")
        } else if !sent.isEmpty {
            parts.append("My answer:\n\(sent)")
        } else {
            parts.append("I have not answered yet. Ask me again in Waggle with waggle_ask.")
        }
        parts.append("Do not ask the same question again. Act on my answer.")
        return parts.joined(separator: "\n\n")
    }

    /// The text of the operator's open choice and note, for a case with no sent reply yet.
    static func draftAnswer(options: [Option], selectedIds: [String], note: String) -> String? {
        let picked = selectedIds.compactMap { id in options.first { $0.id == id } }
            .map { "\($0.displayTitle): \($0.label)" }
        var lines = picked
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { lines.append(text) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The folder of the newest session of this task that has one.
    static func folder(for taskId: String, in sessions: [SessionInfo]) -> URL? {
        let match = sessions
            .filter { $0.taskId == taskId && !$0.cwd.isEmpty }
            .max { $0.connectedAt < $1.connectedAt }
        // Only builds a URL from the stored string for the launcher. Nothing reads the folder here.
        guard let path = match?.cwd else { return nil }
        return URL(fileURLWithPath: path)
    }
}

/// Where the button is, and what it shows. One per case pane.
@MainActor
final class ContinueInNewSessionModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case started
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    private let starter: SessionStarting

    init(starter: SessionStarting) { self.starter = starter }

    func start(item: Case, answer: String?, loadSessions: () async throws -> [SessionInfo]) async {
        guard phase != .starting else { return }
        phase = .starting
        let sessions = (try? await loadSessions()) ?? []
        guard let folder = ContinuePrompt.folder(for: item.taskId, in: sessions) else {
            phase = .failed(ContinueInNewSessionCopy.noFolder)
            return
        }
        let ok = await starter.start(
            prompt: ContinuePrompt.build(for: item, answer: answer), folder: folder, topic: item.title)
        phase = ok ? .started : .failed(ContinueInNewSessionCopy.failedPrefix + "Copy the answer and paste it where you work.")
    }
}

/// Evidence only: `KNOCK_EVIDENCE_CONTINUE_FAKE=1` swaps the launcher for one that opens nothing, so a
/// window capture can show the state after the click. `KNOCK_EVIDENCE_CONTINUE_CLICK=<seconds>` clicks for you.
@MainActor
enum ContinueEvidence {
    private final class OpensNothing: SessionStarting {
        func start(prompt text: String, folder: URL, topic: String) async -> Bool { true }
    }

    static func makeModel(environment: [String: String] = ProcessInfo.processInfo.environment) -> ContinueInNewSessionModel {
        let fake = environment["KNOCK_EVIDENCE_CONTINUE_FAKE"] == "1"
        return ContinueInNewSessionModel(starter: fake ? OpensNothing() : SessionLauncher())
    }

    static var clickDelay: Double? {
        ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_CONTINUE_CLICK"].flatMap(Double.init)
    }
}

/// The "Continue in a new session" button and what it says after the click (WAG-410).
struct ContinueInNewSessionButton: View {
    @ObservedObject var model: ContinueInNewSessionModel
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: action) {
                // The size of the status line's other buttons (C10).
                Text(model.phase == .starting ? ContinueInNewSessionCopy.starting : ContinueInNewSessionCopy.label)
                    .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                    .foregroundColor(Theme.Colors.onFill)
                    .padding(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                    .background(Theme.Colors.ink)
                    .cornerRadius(Theme.Radius.buttonSmall)
                    .fixedSize()
            }
            .buttonStyle(.plain).pointerCursor()
            .disabled(model.phase == .starting)
            switch model.phase {
            case .started:
                Text(ContinueInNewSessionCopy.started)
                    .knockTextStyle(Theme.Typography.caption11_5w400).foregroundColor(Theme.Colors.ink2)
            case .failed(let message):
                Text(message)
                    .knockTextStyle(Theme.Typography.caption11_5w400).foregroundColor(Theme.Colors.accent)
            case .idle, .starting:
                EmptyView()
            }
        }
    }
}
