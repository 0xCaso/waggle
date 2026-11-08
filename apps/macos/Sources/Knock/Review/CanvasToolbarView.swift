import SwiftUI

/// The floating Interact / Comment tool switch over an artifact (HAIL-56 contract, frames `ovd06`/`PPM9l`
/// node `p4VxgR`/`pmToc` "Canvas tools"). Full size and the case page box (WAG-311) share it, so the look,
/// the key hints and the hover cards stay the same. It holds no mode: the owner says which tools show,
/// which one is on, and what a tap does.
struct CanvasToolbarView: View {
    let tools: [ReviewMode]
    let mode: ReviewMode
    /// Whether the I and C hints show. Only a host that binds the keys sets this (full size does; the
    /// case page box does not, so it shows none: WAG-335).
    var showsKeys = true
    let onSelect: (ReviewMode) -> Void

    /// The toolbar's height: 4 pt of padding around a 7 + 16 + 7 pt button (WAG-374). An image stage keeps a band
    /// this tall plus its gaps at the bottom, so the toolbar never covers the image.
    static let height: CGFloat = 38

    /// The bottom inset an image stage takes so the image ends above a toolbar floating `bottomGap` over the stage's
    /// bottom edge, with a 10 pt gap between the toolbar and the image (WAG-374).
    static func imageBottomInset(bottomGap: CGFloat) -> CGFloat { bottomGap + height + 10 }

    @State private var hoveredTool: ReviewMode?
    @State private var hintTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tools, id: \.self) { tool in
                switch tool {
                case .interact:
                    toolButton(.interact, label: "Interact", systemImage: "cursorarrow", key: "I")
                case .comment:
                    toolButton(.comment, label: "Comment", systemImage: "plus.bubble.fill", key: "C")
                }
            }
        }
        .padding(4)
        // Fill and shadow on the shape, not the stack: the hover cards
        // overlay the tool buttons and must not be clipped or double-shadowed.
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.Colors.ink)
                .shadow(
                    color: Theme.Shadow.canvasToolbar.color, radius: Theme.Shadow.canvasToolbar.blur / 2,
                    x: Theme.Shadow.canvasToolbar.offset.width, y: Theme.Shadow.canvasToolbar.offset.height
                )
        )
    }

    private func showsHint(for tool: ReviewMode) -> Bool {
        hoveredTool == tool || CanvasToolHintEvidence.pinnedTool() == tool
    }

    private func toolButton(_ target: ReviewMode, label: String, systemImage: String, key: String) -> some View {
        let isActive = mode == target
        return HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundColor(isActive ? Theme.Colors.ink : Theme.Colors.toolbarInactiveText)
            Text(label)
                .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                .foregroundColor(isActive ? Theme.Colors.ink : Theme.Colors.toolbarInactiveText)
            if showsKeys {
                Text(key)
                    .knockTextStyle(Theme.Typography.toolbarKeyHint10_5w400)
                    .foregroundColor(isActive ? Theme.Colors.ink3 : Theme.Colors.toolbarInactiveKey)
            }
        }
        .padding(EdgeInsets(top: 7, leading: 11, bottom: 7, trailing: 11))
        .background(isActive ? Theme.Colors.win : Color.clear)
        .cornerRadius(Theme.Radius.toolbarButton)
        .contentShape(Rectangle())
        .onTapGesture {
            hintTask?.cancel()
            hoveredTool = nil
            onSelect(target)
        }
        .onHover { inside in
            hintTask?.cancel()
            if inside {
                hintTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(CanvasToolHint.hoverDelay * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    hoveredTool = target
                }
            } else if hoveredTool == target {
                hoveredTool = nil
            }
        }
        .overlay(alignment: .top) {
            if showsHint(for: target) {
                // A zero-height frame with the card bottom-aligned in it: the
                // card grows upward from the button's top edge.
                CanvasToolHintCard(tool: target, showsKey: showsKeys)
                    .fixedSize()
                    .frame(height: 0, alignment: .bottom)
                    .offset(y: -14)
            }
        }
        .zIndex(showsHint(for: target) ? 1 : 0)
    }
}
