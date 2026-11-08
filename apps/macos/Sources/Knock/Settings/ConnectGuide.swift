import AppKit
import SwiftUI

/// Shared pieces of the guided connect flow on the Phone page (HAIL-148): a progress line, a
/// numbered step, a link button that says where it goes, and the token and code boxes.

/// "Step 2 of 4", segmented bars for the steps, and "Start over" on every step.
struct GuideProgress: View {
    let step: Int
    let count: Int
    let startOver: () -> Void
    var busy = false

    var body: some View {
        HStack(spacing: 12) {
            Text("Step \(step) of \(count)")
                .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                .foregroundColor(Theme.Colors.ink)
            HStack(spacing: 4) {
                ForEach(1...count, id: \.self) { i in
                    Capsule()
                        .fill(i <= step ? Theme.Colors.ok : Theme.Colors.line2)
                        .frame(height: 4)
                }
            }
            SettingsSecondaryButton(title: "Start over", action: startOver)
                .disabled(busy)
                .fixedSize()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(step) of \(count)")
    }
}

/// One numbered step. Done steps show a check and the title only. The current step shows its body.
/// Steps to come are dimmed.
struct GuideStep<Content: View>: View {
    let number: Int
    let title: String
    let current: Int
    @ViewBuilder var content: () -> Content

    private var isCurrent: Bool { number == current }
    private var isDone: Bool { number < current }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.Colors.line).frame(height: 1)
            HStack(alignment: .top, spacing: 12) {
                badge
                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .knockTextStyle(Theme.Typography.rowTitle13_5w600)
                        .foregroundColor(isCurrent ? Theme.Colors.ink : Theme.Colors.ink3)
                        .frame(minHeight: 22, alignment: .leading)
                    if isCurrent { content() }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
        }
        .accessibilityElement(children: .contain)
    }

    private var badge: some View {
        ZStack {
            Circle().fill(isDone ? Theme.Colors.stepDoneCircle : (isCurrent ? Theme.Colors.ink : Theme.Colors.side))
            if isDone {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.Colors.ok)
            } else {
                Text("\(number)")
                    .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                    .foregroundColor(isCurrent ? Theme.Colors.win : Theme.Colors.ink3)
            }
        }
        .frame(width: 22, height: 22)
    }
}

/// Plain body copy for a step.
struct GuideText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .knockTextStyle(Theme.Typography.body12_5w400)
            .foregroundColor(Theme.Colors.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A button that opens a link, with the destination on hover (help tip) and in words under it.
struct GuideLinkButton: View {
    let title: String
    let url: URL?
    var primary = true
    let open: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if primary {
                    SettingsPrimaryButton(icon: "arrow.up.right", title: title, action: tap)
                } else {
                    SettingsSecondaryButton(icon: "arrow.up.right", title: title, action: tap)
                }
            }
            .disabled(url == nil)
            .help(url.map(Self.hover) ?? "")
            if let url {
                Text("Opens \(ConnectorLinks.destination(url))")
                    .knockTextStyle(Theme.Typography.monoMeta11w400)
                    .foregroundColor(Theme.Colors.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func tap() {
        if let url { open(url) }
    }

    private static func hover(_ url: URL) -> String {
        url.scheme == "https" ? "Opens \(ConnectorLinks.destination(url)) in your browser" : "Opens \(url.absoluteString)"
    }
}

/// A one-line monospaced box for a pasted token, with its own problem text under it.
struct GuideTokenField: View {
    let placeholder: String
    @Binding var text: String
    var problem: String?
    var onSubmit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .knockTextStyle(Theme.Typography.monoMeta12w400)
                .foregroundColor(Theme.Colors.ink)
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .background(Theme.Colors.list)
                .cornerRadius(Theme.Radius.buttonSmall)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.buttonSmall)
                        .stroke(problem == nil ? Theme.Colors.line2 : Theme.Colors.accent, lineWidth: 1)
                )
                .onSubmit(onSubmit)
            if let problem {
                Text(problem)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The one-time code in a box, with Copy as the fallback and the waiting line.
struct GuideCodeRow: View {
    /// What the box shows and Copy puts on the pasteboard.
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
                .knockTextStyle(Theme.Typography.monoMeta12w400)
                .foregroundColor(Theme.Colors.ink)
                .textSelection(.enabled)
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .background(Theme.Colors.list)
                .cornerRadius(Theme.Radius.buttonSmall)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.buttonSmall).stroke(Theme.Colors.line2, lineWidth: 1))
            SettingsSecondaryButton(icon: "doc.on.doc", title: "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .help("Copies \(text)")
            Spacer(minLength: 0)
            Text("Waiting for your message…")
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(Theme.Colors.ink3)
        }
    }
}

/// Next and Back for the steps that only the operator can finish (they happen in another app).
struct GuideNav: View {
    var back: (() -> Void)?
    var next: (() -> Void)?
    var nextTitle = "Next"
    var nextEnabled = true

    var body: some View {
        HStack(spacing: 8) {
            if let back { SettingsSecondaryButton(title: "Back", action: back) }
            if let next {
                SettingsSecondaryButton(title: nextTitle, action: next)
                    .disabled(!nextEnabled)
                    .opacity(nextEnabled ? 1 : 0.5)
            }
            Spacer(minLength: 0)
        }
    }
}
