import AppKit
import SwiftUI

/// The "confirm before opening" gate for a markdown link (HAIL-33: "Links
/// open in the default browser, only after a confirmation"). A tapped link
/// never opens immediately - `requestOpen` only ever records it as pending;
/// only `confirm()` actually opens it. Pulled out of `MarkdownView` as a
/// pure, `@MainActor` state machine so the "never opens without a
/// confirmation" rule is testable without hosting the view (the same
/// pattern `ComposerPlaceholder`/`CasePaneDetailView.footerKind` already
/// use for view logic that needs to be unit-tested directly).
@MainActor
final class MarkdownLinkGate: ObservableObject {
    @Published private(set) var pendingURL: URL?

    func requestOpen(_ url: URL) {
        pendingURL = url
    }

    /// Opens the pending link through `open` (production: `NSWorkspace.
    /// shared.open`) and clears it. A no-op with nothing pending.
    func confirm(open: (URL) -> Void) {
        guard let pendingURL else { return }
        open(pendingURL)
        self.pendingURL = nil
    }

    func cancel() {
        pendingURL = nil
    }
}

/// Renders a markdown artifact's text with the app's own typography
/// (HAIL-33: "headings, lists, code blocks, tables and links ... Links open
/// in the default browser, only after a confirmation. No remote images, no
/// scripts."). The confirmation itself is the Previews page's "Ask before
/// opening links" toggle (HAIL-52, on by default): off skips `linkGate`
/// entirely and opens straight away, on keeps this gate exactly as before.
/// Every existing `Theme` token this reuses is one the review viewer already
/// uses elsewhere (see the story's Choices ledger: the design has no frame
/// for a markdown artifact, so this reuses established tokens rather than
/// inventing new ones).
struct MarkdownView: View {
    let text: String

    @StateObject private var linkGate = MarkdownLinkGate()

    private var blocks: [MarkdownBlock] { MarkdownDocument.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            switch LinkOpenPolicy.decide(confirmEnabled: LinkConfirmSettings.isEnabled()) {
            case .confirm:
                linkGate.requestOpen(url)
            case .openDirectly:
                NSWorkspace.shared.open(url)
            }
            return .handled
        })
        .alert(
            "Open this link?",
            isPresented: Binding(get: { linkGate.pendingURL != nil }, set: { if !$0 { linkGate.cancel() } })
        ) {
            Button("Cancel", role: .cancel) { linkGate.cancel() }
            Button("Open") { linkGate.confirm(open: { NSWorkspace.shared.open($0) }) }
        } message: {
            Text(linkGate.pendingURL?.absoluteString ?? "")
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownDocument.inline(text))
                .knockTextStyle(headingStyle(level))
                .foregroundColor(Theme.Colors.ink)
        case .paragraph(let text):
            Text(MarkdownDocument.inline(text))
                .knockTextStyle(Theme.Typography.body13w400)
                .foregroundColor(Theme.Colors.ink)
        case .listItem(let ordered, let index, let text):
            HStack(alignment: .top, spacing: 8) {
                Text(ordered ? "\(index)." : "•")
                    .knockTextStyle(Theme.Typography.body13w400)
                    .foregroundColor(Theme.Colors.ink3)
                    .frame(minWidth: 14, alignment: .trailing)
                Text(MarkdownDocument.inline(text))
                    .knockTextStyle(Theme.Typography.body13w400)
                    .foregroundColor(Theme.Colors.ink)
            }
        case .codeBlock(let text):
            Text(text)
                .knockTextStyle(Theme.Typography.monoMeta12w400)
                .foregroundColor(Theme.Colors.ink)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.side)
                .cornerRadius(Theme.Radius.card)
        case .table(let headers, let rows):
            MarkdownTableView(headers: headers, rows: rows)
        }
    }

    private func headingStyle(_ level: Int) -> Theme.TextStyle {
        switch level {
        case 1: Theme.Typography.cardTitle15w650
        case 2: Theme.Typography.rowTitle13_5w600
        default: Theme.Typography.buttonSm12_5w600
        }
    }
}

/// A plain grid table (HAIL-33): no column sizing beyond equal-ish spacing -
/// this is a short explanation's table, not a data grid.
private struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(headers, isHeader: true)
            Rectangle().fill(Theme.Colors.line).frame(height: 1)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                row(cells, isHeader: false)
                if index < rows.count - 1 {
                    Rectangle().fill(Theme.Colors.line).frame(height: 1)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(Theme.Stroke.card.color, lineWidth: Theme.Stroke.card.width)
        )
        .cornerRadius(Theme.Radius.card)
    }

    private func row(_ cells: [String], isHeader: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(MarkdownDocument.inline(cell))
                    .knockTextStyle(isHeader ? Theme.Typography.buttonSm12_5w600 : Theme.Typography.body12_5w400)
                    .foregroundColor(isHeader ? Theme.Colors.ink : Theme.Colors.ink2)
                    .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(isHeader ? Theme.Colors.side : Color.clear)
    }
}
