import SwiftUI

/// A progress note (waggle_update with working: true, WAG-377). The case stays with the agent, so the page shows
/// a pulsing "Working on it" line with the note, and the earlier round folds under it.
extension Case {
    /// The progress note while it is the newest message, or nil. Never for a closed or dismissed case.
    var workingNoteText: String? {
        guard status == .waitingOnAgent, !isDone else { return nil }
        let text = (workingNote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

enum WorkingNoteCopy {
    static let title = "Working on it"
}

/// The line on the agent side: a blue dot that pulses a ring, "Working on it" and the note under it.
/// Reduce Motion shows the same line still.
struct WorkingNoteLine: View {
    let note: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Theme.Colors.ds)
                .frame(width: 8, height: 8)
                .overlay {
                    if !reduceMotion { PulseRing(color: Theme.Colors.ds, lineWidth: 1.5, opacity: 0.8, scale: 2.4) }
                }
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(WorkingNoteCopy.title)
                    .knockTextStyle(Theme.Typography.rowLabel12_5w500)
                    .foregroundColor(Theme.Colors.ds)
                AgentMarkdownText(text: note)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.dsUpdateFill)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.recommendedBlock).stroke(Theme.Colors.ds.opacity(0.25), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.recommendedBlock))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(WorkingNoteCopy.title). \(note)")
        .accessibilityIdentifier("working-note-line")
    }
}
