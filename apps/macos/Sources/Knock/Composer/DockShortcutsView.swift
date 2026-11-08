import SwiftUI

/// The hidden keys of an answer dock (WAG-334): Cmd-D takes the recommendation, Cmd-Return sends, the digit keys
/// 1 to 9 pick a row, Return sends the ticks, and "?" opens "Ask for more detail". One view for the single dock
/// (`ComposerCardView`) and the steps dock (`AnswersBarView`), so a key means the same in both. The digit, Return
/// and "?" keys guard on `isTextFocused` in their action: AppKit resolves a plain key equivalent before it routes
/// the keystroke to the focused text field, so the guard has to live in the action.
struct DockShortcutsView: View {
    /// While the detail panel is open it wires its own keys (1 to 5, Esc, Cmd-Return).
    var isAskingForDetail = false
    var isTextFocused: Bool
    /// Return acts as the primary button while ticks are made on a pick-several point.
    var returnActs = false
    let onAccept: () -> Void
    let onSend: () -> Void
    let onPick: (Int) -> Void
    let onReturn: () -> Void
    let onAskForDetail: () -> Void

    var body: some View {
        HStack {
            if !isAskingForDetail {
                Button("Accept recommendation", action: onAccept)
                    .keyboardShortcut("d", modifiers: .command)
                Button("Send", action: onSend)
                    .keyboardShortcut(.return, modifiers: .command)
                ForEach(1...9, id: \.self) { digit in
                    Button("Pick \(digit)") {
                        guard !isTextFocused else { return }
                        onPick(digit)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(digit)")), modifiers: [])
                }
                if returnActs {
                    Button("Send picks") { if !isTextFocused { onReturn() } }
                        .keyboardShortcut(.return, modifiers: [])
                }
                // "?" opens "Ask for more detail" (HAIL-111); shift+/ is the same key on a US layout.
                Button("Ask for more detail") { if !isTextFocused { onAskForDetail() } }
                    .keyboardShortcut("?", modifiers: [])
                Button("Ask for more detail (shift)") { if !isTextFocused { onAskForDetail() } }
                    .keyboardShortcut("/", modifiers: .shift)
            }
        }
        .opacity(0)
    }
}
