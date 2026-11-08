import SwiftUI

/// Pure content for the canvas toolbar's hover card (HAIL-58, Pen frame
/// `anHve`): one title line and one description line per tool.
struct CanvasToolHint: Equatable {
    let title: String
    let detail: String

    /// How long the pointer rests on a tool before its card shows.
    static let hoverDelay: TimeInterval = 0.4

    /// `showsKey` is false where the key does nothing (the case page box, WAG-335).
    static func content(for tool: ReviewMode, showsKey: Bool = true) -> CanvasToolHint {
        switch tool {
        case .interact:
            return CanvasToolHint(title: showsKey ? "Interact · I" : "Interact", detail: "Click through it like a user.")
        case .comment:
            return CanvasToolHint(title: showsKey ? "Comment · C" : "Comment", detail: "Drag over anything to flag it.")
        }
    }
}

/// The "Drag to flag" cursor tag rule (HAIL-58, Pen frame `roByV`): shown in
/// Comment mode until the first comment the operator ever places. Persisted
/// in `UserDefaults` (a test or evidence copy gets its own domain from its
/// bundle id, like `LinkConfirmSettings`).
enum CommentCursorTag {
    static let defaultsKey = "review.hasPlacedComment"
    static let label = "Drag to flag"

    static func isVisible(mode: ReviewMode, hasPlacedComment: Bool) -> Bool {
        mode == .comment && !hasPlacedComment
    }

    static func hasPlacedComment(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    static func markPlaced(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: defaultsKey)
    }
}

/// `KNOCK_EVIDENCE_TOOL_HINT=interact|comment|cursor` (HAIL-58 evidence
/// hook): `interact`/`comment` pin that tool's hover card open; `cursor`
/// pins the cursor tag at a fixed canvas point. Nothing without the env var.
enum CanvasToolHintEvidence {
    static func value(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        environment["KNOCK_EVIDENCE_TOOL_HINT"]
    }

    static func pinnedTool(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> ReviewMode? {
        switch value(environment) {
        case "interact": return .interact
        case "comment": return .comment
        default: return nil
        }
    }

    static func pinsCursorTag(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        value(environment) == "cursor"
    }

    /// Where the pinned tag sits, in the stage's own coordinates.
    static let cursorPoint = CGPoint(x: 180, y: 140)
}

/// The dark hover card above a tool button (ink fill, radius 10, 220 wide).
struct CanvasToolHintCard: View {
    let tool: ReviewMode
    var showsKey = true

    var body: some View {
        let hint = CanvasToolHint.content(for: tool, showsKey: showsKey)
        VStack(alignment: .leading, spacing: 0) {
            illustration
                .frame(maxWidth: .infinity)
                .frame(height: 72)
                .background(Theme.Colors.onFill.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(hint.title)
                .knockTextStyle(Theme.Typography.buttonSm12_5w500)
                .fontWeight(.semibold)
                .foregroundColor(Theme.Colors.onFill)
                .padding(.top, 10)
            Text(hint.detail)
                .knockTextStyle(Theme.Typography.keyHint11_5w400)
                .foregroundColor(Theme.Colors.onFill.opacity(0.7))
                .padding(.top, 3)
        }
        .padding(10)
        .frame(width: 220, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.Colors.ink)
                .shadow(
                    color: Theme.Shadow.canvasToolbar.color, radius: Theme.Shadow.canvasToolbar.blur / 2,
                    x: Theme.Shadow.canvasToolbar.offset.width, y: Theme.Shadow.canvasToolbar.offset.height
                )
        )
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var illustration: some View {
        switch tool {
        case .interact:
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Theme.Colors.onFill.opacity(0.85))
                    .frame(width: 64, height: 22)
                Circle()
                    .stroke(Theme.Colors.ds, lineWidth: 2)
                    .frame(width: 34, height: 34)
                Image(systemName: "cursorarrow")
                    .font(.system(size: 16))
                    .foregroundColor(Theme.Colors.ds)
                    .offset(x: 16, y: 14)
            }
        case .comment:
            ZStack {
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.Colors.onFill.opacity(0.35)).frame(width: 120, height: 9)
                    RoundedRectangle(cornerRadius: 3).fill(Theme.Colors.onFill.opacity(0.35)).frame(width: 90, height: 9)
                }
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Theme.Colors.accent, lineWidth: 1.5)
                    .background(Theme.Colors.accent.opacity(0.15))
                    .frame(width: 100, height: 19)
                    .offset(x: -15, y: 10.5)
                Circle()
                    .fill(Theme.Colors.accent)
                    .frame(width: 9, height: 9)
                    .offset(x: -65, y: 1)
            }
        }
    }
}

/// The small hail tag that follows the crosshair cursor.
struct CommentCursorTagView: View {
    var body: some View {
        Text(CommentCursorTag.label)
            .knockTextStyle(Theme.Typography.badgeLabel11w500)
            .fontWeight(.semibold)
            .foregroundColor(Theme.Colors.onFill)
            .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
            .background(Theme.Colors.accent)
            .cornerRadius(6)
            .fixedSize()
            .allowsHitTesting(false)
    }
}
