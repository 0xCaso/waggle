import SwiftUI

/// WAG-323: a `screenshots` set in the artifact box, flipped through where it sits. Prev and next arrows on the
/// image edges (on hover, always with keyboard focus), dots under the image (small thumbnails from 600 pt),
/// and the same caption line as full size. Full size is for zoom and Set mode.
struct ScreenSetBoxView: View {
    @ObservedObject var store: CommentsSessionStore
    let capture: CaptureRecord
    var fillsHeight = false
    /// The box has keyboard focus: the arrows stay on show.
    var hasFocus = false
    /// Space under the image for the floating toolbar, so it never covers the image (WAG-374).
    var imageBottomInset: CGFloat = 0
    let onStep: (Int) -> Void
    let onSelect: (String) -> Void

    @State private var isHovering = false
    @State private var width: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// From this box width the dots become small thumbnails.
    static let thumbnailWidth: CGFloat = 600
    private static let thumbHeight: CGFloat = 40

    private var screens: [CaptureRecord] { store.screens }

    private var index: ScreenSetIndex {
        ScreenSetIndex(count: screens.count, current: screens.firstIndex { $0.id == capture.id } ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            PinnedStillView(store: store, capture: capture, fillsHeight: fillsHeight)
                .frame(maxHeight: fillsHeight ? .infinity : nil)
                .overlay { arrows }
                .padding(.bottom, imageBottomInset)
                .onHover { isHovering = $0 }
            VStack(spacing: 8) {
                if width >= Self.thumbnailWidth { thumbnails } else { dots }
                Text(FilmstripText.label(index: index.current + 1, total: screens.count, title: store.screenTitle(for: capture)))
                    .knockTextStyle(Theme.Typography.monoMeta12w400)
                    .foregroundColor(Theme.Colors.ink2)
                    .lineLimit(1).truncationMode(.tail)
            }
            .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
            .frame(maxWidth: .infinity)
            .background(Theme.Colors.side)
            .overlay(Rectangle().fill(Theme.Colors.line).frame(height: 1), alignment: .top)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }

    // MARK: Arrows

    private var arrows: some View {
        let visible = isHovering || hasFocus
        return HStack {
            arrow("chevron.left", label: "Previous screen", enabled: index.canGoPrevious) { onStep(-1) }
            Spacer(minLength: 0)
            arrow("chevron.right", label: "Next screen", enabled: index.canGoNext) { onStep(1) }
        }
        .padding(.horizontal, 10)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: visible)
    }

    private func arrow(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(enabled ? Theme.Colors.ink : Theme.Colors.ink3)
                .frame(width: 30, height: 30)
                .background(Theme.Colors.win.opacity(enabled ? 0.95 : 0.7))
                .clipShape(Circle())
                .overlay(Circle().stroke(Theme.Colors.line2, lineWidth: 1))
                .shadow(color: Theme.Colors.shadowBlack.opacity(0.10), radius: 4, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain).pointerCursor()
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: Dots and thumbnails

    private func commentCount(_ screen: CaptureRecord) -> Int { store.model.comments(on: screen.id).count }

    private var dots: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(screens.enumerated()), id: \.element.id) { position, screen in
                    let isCurrent = screen.id == capture.id
                    let count = commentCount(screen)
                    Button { onSelect(screen.id) } label: {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(isCurrent ? Theme.Colors.ink : Theme.Colors.line2)
                                .frame(width: 8, height: 8)
                            if count > 0 {
                                Text("\(count)")
                                    .knockTextStyle(Theme.Typography.pinNumber9_5w700)
                                    .foregroundColor(Theme.Colors.accent)
                            }
                        }
                        .padding(EdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).pointerCursor()
                    .help(store.screenTitle(for: screen))
                    .accessibilityLabel("Screen \(position + 1)")
                    .accessibilityAddTraits(isCurrent ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var thumbnails: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(screens.enumerated()), id: \.element.id) { position, screen in
                        thumbnail(screen, position: position).id(screen.id)
                    }
                }
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: capture.id) { _, id in proxy.scrollTo(id) }
        }
    }

    @ViewBuilder
    private func thumbnail(_ screen: CaptureRecord, position: Int) -> some View {
        if let image = store.imagesByCaptureId[screen.id] {
            let isCurrent = screen.id == capture.id
            let count = commentCount(screen)
            let aspect = image.size.width / max(image.size.height, 1)
            Button { onSelect(screen.id) } label: {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.thumbHeight * min(max(aspect, 0.4), 2.2), height: Self.thumbHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isCurrent ? Theme.Colors.ink : Theme.Stroke.card.color, lineWidth: isCurrent ? 2 : Theme.Stroke.card.width))
                    .overlay(alignment: .topTrailing) {
                        if count > 0 {
                            Text("\(count)")
                                .knockTextStyle(Theme.Typography.pinNumber9_5w700)
                                .foregroundColor(Theme.Colors.win)
                                .frame(minWidth: 14, minHeight: 14)
                                .background(Capsule().fill(Theme.Colors.accent))
                                .offset(x: 4, y: -4)
                        }
                    }
            }
            .buttonStyle(.plain).pointerCursor()
            .help(store.screenTitle(for: screen))
            .accessibilityLabel("Screen \(position + 1)")
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
        }
    }
}
