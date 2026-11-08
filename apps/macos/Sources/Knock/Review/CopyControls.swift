import AppKit
import SwiftUI

/// Copy to the clipboard with a short "Copied" confirmation (HAIL-94).
struct CopyPill: View {
    let label: String
    let copies: String
    var mono = false

    @State private var copied = false

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(copies, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
                Text(copied ? "Copied" : label)
                    .font(mono && !copied ? .custom(Theme.FontFamily.mono, size: 10.5) : .custom(Theme.FontFamily.sans, size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundColor(copied ? Theme.Colors.ok : Theme.Colors.ink2)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.Colors.win.opacity(0.92))
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.Colors.line, lineWidth: 1))
        }
        .buttonStyle(.plain).pointerCursor()
        .help("Copy")
        .accessibilityLabel(copied ? "Copied" : "Copy")
    }
}

/// Evidence hook (HAIL-94): `KNOCK_EVIDENCE_FORCE_HOVER=1` shows every hover Copy button.
enum CopyHover {
    static let forced = ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_FORCE_HOVER"] == "1"
}

private struct CopyOnHover: ViewModifier {
    let text: String
    let outsideLeading: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: outsideLeading ? .topLeading : .topTrailing) {
                if !text.isEmpty, hovering || CopyHover.forced {
                    if outsideLeading {
                        // Beside the bubble, not on it: a short dark "you"
                        // bubble has no room without covering its time.
                        // A zero-width frame anchored trailing lets the pill grow leftwards from
                        // the bubble's leading edge (an alignment guide was ignored here).
                        CopyPill(label: "Copy", copies: text)
                            .fixedSize()
                            .frame(width: 0, alignment: .trailing)
                            .offset(x: -6)
                    } else {
                        CopyPill(label: "Copy", copies: text).padding(5)
                    }
                }
            }
            .onHover { hovering = $0 }
    }
}

extension View {
    /// A small Copy button in the top right corner while the pointer is over the view.
    /// `outsideLeading` puts it just left of the view instead (the right-aligned "you" bubble).
    func copyOnHover(_ text: String, outsideLeading: Bool = false) -> some View {
        modifier(CopyOnHover(text: text, outsideLeading: outsideLeading))
    }
}
