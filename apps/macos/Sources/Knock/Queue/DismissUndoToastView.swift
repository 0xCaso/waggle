import SwiftUI

/// The 5 s Undo toast a dismiss leaves behind (docs/stories/HAIL-32.md: "an
/// Undo toast for 5 s calls case.restore"). `AppModel` owns the 5 s timer
/// (`dismissUndo` clears itself); this view is purely presentational.
struct DismissUndoToastView: View {
    let undo: DismissUndo
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("Dismissed \"\(undo.title)\"")
                .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                .foregroundColor(Theme.Colors.win)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text("Undo")
                .knockTextStyle(Theme.Typography.deliveryRetryLabel12w500)
                .foregroundColor(Theme.Colors.win)
                .contentShape(Rectangle())
                .onTapGesture(perform: onUndo).pointerCursor()
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        .background(Theme.Colors.ink)
        .cornerRadius(Theme.Radius.deliveryBanner)
        .padding(EdgeInsets(top: 0, leading: 12, bottom: 12, trailing: 12))
    }
}
